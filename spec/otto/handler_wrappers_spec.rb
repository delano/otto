# spec/otto/handler_wrappers_spec.rb
#
# frozen_string_literal: true
#
# Coverage for Otto#register_handler_wrapper (issue #130): public API surface,
# composition order around RouteAuthWrapper, block arguments, TypeError on
# bad return values, frozen-config guard, multi-instance isolation, and the
# zero-overhead path through HandlerFactory.apply_handler_wrappers.

require_relative '../spec_helper'

RSpec.describe 'Otto#register_handler_wrapper' do
  # Recording wrapper: pushes its tag to a shared array on construction-time
  # call, then delegates. Use as a spy for both static chain inspection
  # (via #inner) and dynamic execution-order assertions (via the shared log).
  let(:recording_wrapper_class) do
    Class.new do
      attr_reader :inner, :tag, :log

      def initialize(inner, tag, log)
        @inner = inner
        @tag = tag
        @log = log
      end

      def call(env, extra_params = {})
        @log << @tag
        @inner.call(env, extra_params)
      end
    end
  end

  let(:route_lines) do
    [
      'GET / TestApp.index',
      'GET /show/:id TestApp.show',
    ]
  end

  let(:otto) { create_minimal_otto(route_lines) }

  describe 'API surface' do
    it 'returns self to support chaining' do
      result = otto.register_handler_wrapper { |_rd, inner| inner }
      expect(result).to equal(otto)
    end

    it 'chains multiple registrations on a single line' do
      chained = otto
                .register_handler_wrapper { |_rd, inner| inner }
                .register_handler_wrapper { |_rd, inner| inner }
                .register_handler_wrapper { |_rd, inner| inner }

      expect(chained).to equal(otto)
      expect(otto.handler_wrappers.length).to eq(3)
    end

    it 'exposes registered blocks via #handler_wrappers' do
      block = proc { |_rd, inner| inner }
      otto.register_handler_wrapper(&block)

      expect(otto.handler_wrappers).to be_an(Array)
      expect(otto.handler_wrappers.length).to eq(1)
      expect(otto.handler_wrappers.first).to equal(block)
    end

    it 'is a no-op when called without a block' do
      otto.register_handler_wrapper
      expect(otto.handler_wrappers).to be_empty
    end

    it 'starts with an empty wrapper list' do
      expect(otto.handler_wrappers).to eq([])
    end
  end

  describe 'composition order at request time' do
    it 'invokes consumer wrappers outermost-first in registration order' do
      execution_log = []

      otto.register_handler_wrapper do |_rd, inner|
        recording_wrapper_class.new(inner, :wrapper_a, execution_log)
      end
      otto.register_handler_wrapper do |_rd, inner|
        recording_wrapper_class.new(inner, :wrapper_b, execution_log)
      end

      # Wrap the base handler so we can record when it actually runs.
      allow(TestApp).to receive(:index).and_wrap_original do |original, *args|
        execution_log << :base_handler
        original.call(*args)
      end

      otto.call(mock_rack_env(method: 'GET', path: '/'))

      # First registered (a) is outermost; second (b) sits inside a.
      # RouteAuthWrapper runs between b and the base handler but does not
      # appear in this log because it is not a recording wrapper.
      expect(execution_log).to eq(%i[wrapper_a wrapper_b base_handler])
    end

    it 'fires three wrappers in the order they were registered' do
      execution_log = []
      %i[outer middle inner].each do |tag|
        otto.register_handler_wrapper do |_rd, inner_handler|
          recording_wrapper_class.new(inner_handler, tag, execution_log)
        end
      end

      otto.call(mock_rack_env(method: 'GET', path: '/'))

      expect(execution_log).to eq(%i[outer middle inner])
    end

    it 'composes the static wrapper chain so the first wrapper is the outermost object' do
      otto.register_handler_wrapper do |_rd, inner|
        recording_wrapper_class.new(inner, :outer, [])
      end
      otto.register_handler_wrapper do |_rd, inner|
        recording_wrapper_class.new(inner, :inner_consumer, [])
      end

      route_def = otto.route_definitions.values.first
      handler = Otto::RouteHandlers::HandlerFactory.create_handler(route_def, otto)

      expect(handler).to be_a(recording_wrapper_class)
      expect(handler.tag).to eq(:outer)
      expect(handler.inner).to be_a(recording_wrapper_class)
      expect(handler.inner.tag).to eq(:inner_consumer)
    end
  end

  describe 'block arguments' do
    it 'yields (route_definition, inner_handler) with a callable handler and route metadata' do
      captured_rd = nil
      captured_inner = nil

      otto.register_handler_wrapper do |route_definition, inner_handler|
        captured_rd = route_definition
        captured_inner = inner_handler
        inner_handler
      end

      otto.call(mock_rack_env(method: 'GET', path: '/show/42'))

      expect(captured_rd).to be_a(Otto::RouteDefinition)
      expect(captured_rd.path).to eq('/show/:id')
      expect(captured_rd.verb).to eq(:GET)
      expect(captured_rd.options).to be_a(Hash)
      expect(captured_inner).to respond_to(:call)
    end

    it 'lets the wrapper inspect arbitrary route options' do
      # Route file with a custom option; option(:scope) drives gating.
      lines = ['GET /canon TestApp.index scope=canonical']
      gated_otto = create_minimal_otto(lines)

      scopes_seen = []
      gated_otto.register_handler_wrapper do |route_definition, inner|
        scopes_seen << route_definition.option(:scope)
        inner
      end

      gated_otto.call(mock_rack_env(method: 'GET', path: '/canon'))

      expect(scopes_seen).to eq(['canonical'])
    end
  end

  describe 'passthrough vs wrapping' do
    it 'is transparent when the wrapper returns inner_handler unchanged' do
      called = false
      otto.register_handler_wrapper do |_rd, inner|
        called = true
        inner
      end

      status, _headers, body = otto.call(mock_rack_env(method: 'GET', path: '/'))

      expect(called).to be true
      expect(status).to eq(200)
      expect(body.first).to include('Hello World')
    end

    it 'interposes when the wrapper returns a new callable' do
      execution_log = []

      otto.register_handler_wrapper do |_rd, inner|
        recording_wrapper_class.new(inner, :interposed, execution_log)
      end

      status, = otto.call(mock_rack_env(method: 'GET', path: '/'))

      expect(status).to eq(200)
      expect(execution_log).to eq([:interposed])
    end

    it 'lets a wrapper short-circuit the response' do
      otto.register_handler_wrapper do |_rd, _inner|
        ->(_env, _extra = {}) { [418, { 'Content-Type' => 'text/plain' }, ["I'm a teapot"]] }
      end

      status, headers, body = otto.call(mock_rack_env(method: 'GET', path: '/'))

      expect(status).to eq(418)
      expect(headers['Content-Type']).to eq('text/plain')
      expect(body).to eq(["I'm a teapot"])
    end
  end

  describe 'TypeError on bad wrapper return values' do
    let(:route_def) { Otto::RouteDefinition.new('GET', '/test', 'TestApp.index') }

    it 'raises TypeError when the wrapper returns nil' do
      otto.register_handler_wrapper { |_rd, _inner| nil }

      expect do
        Otto::RouteHandlers::HandlerFactory.create_handler(route_def, otto)
      end.to raise_error(TypeError, /handler wrapper must return an object responding to :call, got NilClass/)
    end

    it 'raises TypeError when the wrapper returns false' do
      otto.register_handler_wrapper { |_rd, _inner| false }

      expect do
        Otto::RouteHandlers::HandlerFactory.create_handler(route_def, otto)
      end.to raise_error(TypeError, /got FalseClass/)
    end

    it 'raises TypeError naming the class of a non-callable return value' do
      bad_class = Class.new
      stub_const('NotCallable', bad_class)
      otto.register_handler_wrapper { |_rd, _inner| bad_class.new }

      expect do
        Otto::RouteHandlers::HandlerFactory.create_handler(route_def, otto)
      end.to raise_error(TypeError, /got NotCallable/)
    end
  end

  describe 'frozen configuration guard' do
    it 'raises FrozenError when registered after configuration freeze' do
      frozen_otto = create_minimal_otto(route_lines)
      frozen_otto.freeze_configuration!

      expect do
        frozen_otto.register_handler_wrapper { |_rd, inner| inner }
      end.to raise_error(FrozenError, /Cannot modify frozen configuration/)
    end
  end

  describe 'boot-time validation via freeze_configuration!' do
    it 'raises TypeError at boot when any registered wrapper returns a non-callable' do
      boot_otto = create_minimal_otto(route_lines)
      boot_otto.register_handler_wrapper { |_rd, _inner| nil }

      expect do
        boot_otto.freeze_configuration!
      end.to raise_error(TypeError, /handler wrapper must return an object responding to :call, got NilClass/)
    end

    it 'raises at boot when a registered wrapper raises for any loaded route' do
      boot_otto = create_minimal_otto(route_lines)
      boot_otto.register_handler_wrapper do |_rd, _inner|
        raise 'factory exploded'
      end

      expect do
        boot_otto.freeze_configuration!
      end.to raise_error(RuntimeError, /factory exploded/)
    end

    it 'is a no-op when no handler wrappers are registered' do
      boot_otto = create_minimal_otto(route_lines)

      expect { boot_otto.freeze_configuration! }.not_to raise_error
    end
  end

  describe 'multi-instance isolation' do
    it 'does not leak registrations from one Otto instance to another' do
      otto_a = create_minimal_otto(route_lines)
      otto_b = create_minimal_otto(route_lines)

      a_invocations = []
      otto_a.register_handler_wrapper do |_rd, inner|
        recording_wrapper_class.new(inner, :a_only, a_invocations)
      end

      expect(otto_a.handler_wrappers.length).to eq(1)
      expect(otto_b.handler_wrappers).to be_empty

      otto_b.call(mock_rack_env(method: 'GET', path: '/'))

      expect(a_invocations).to be_empty
    end
  end

  describe 'RouteAuthWrapper invariant' do
    it 'keeps RouteAuthWrapper as the innermost wrapper between consumer wrappers and the base handler' do
      otto.register_handler_wrapper do |_rd, inner|
        recording_wrapper_class.new(inner, :outer, [])
      end
      otto.register_handler_wrapper do |_rd, inner|
        recording_wrapper_class.new(inner, :inner_consumer, [])
      end

      route_def = otto.route_definitions.values.first
      handler = Otto::RouteHandlers::HandlerFactory.create_handler(route_def, otto)

      # Walk: outer -> inner_consumer -> RouteAuthWrapper -> base handler.
      expect(handler).to be_a(recording_wrapper_class)
      expect(handler.tag).to eq(:outer)

      second = handler.inner
      expect(second).to be_a(recording_wrapper_class)
      expect(second.tag).to eq(:inner_consumer)

      auth_wrapper = second.inner
      expect(auth_wrapper).to be_a(Otto::Security::Authentication::RouteAuthWrapper)

      base_handler = auth_wrapper.wrapped_handler
      expect(base_handler).to be_a(Otto::RouteHandlers::BaseHandler)
    end

    it 'lets consumer wrappers observe env state set by RouteAuthWrapper' do
      captured_strategy_results = []

      otto.register_handler_wrapper do |_rd, inner|
        # This wrapper sits outside RouteAuthWrapper, so when its call body
        # delegates inward and control returns, env has been mutated by the
        # inner RouteAuthWrapper. To observe the inside-the-chain state we
        # check env AFTER the inner call returns.
        wrapper = Class.new do
          define_method(:initialize) { |i| @inner = i }
          define_method(:call) do |env, extra = {}|
            result = @inner.call(env, extra)
            captured_strategy_results << env['otto.strategy_result']
            result
          end
        end
        wrapper.new(inner)
      end

      otto.call(mock_rack_env(method: 'GET', path: '/'))

      expect(captured_strategy_results.length).to eq(1)
      # RouteAuthWrapper sets an anonymous StrategyResult for routes without
      # auth requirements; verify the wrapper saw the env mutation.
      expect(captured_strategy_results.first).not_to be_nil
      expect(captured_strategy_results.first).to respond_to(:anonymous?)
    end
  end

  describe 'per-request isolation (no state leak between requests)' do
    it 'constructs a fresh wrapper instance per request' do
      instances = []
      otto.register_handler_wrapper do |_rd, inner|
        w = recording_wrapper_class.new(inner, :iso, [])
        instances << w
        w
      end

      3.times { otto.call(mock_rack_env(method: 'GET', path: '/')) }

      expect(instances.length).to eq(3)
      expect(instances.map(&:object_id).uniq.length).to eq(3)
    end

    it 'does not let wrapper instance state survive across requests' do
      # @count is incremented on call; snapshot at entry must be 0 every time
      # since each request should see a fresh wrapper instance.
      stateful_wrapper = Class.new do
        attr_reader :count_at_entry

        def initialize(inner)
          @inner = inner
          @count = 0
        end

        def call(env, extra = {})
          @count_at_entry = @count
          @count += 1
          @inner.call(env, extra)
        end
      end

      entries = []
      otto.register_handler_wrapper do |_rd, inner|
        w = stateful_wrapper.new(inner)
        entries << w
        w
      end

      3.times { otto.call(mock_rack_env(method: 'GET', path: '/')) }

      expect(entries.length).to eq(3)
      expect(entries.map(&:count_at_entry)).to eq([0, 0, 0])
    end

    it 'persists factory closure variables across requests (confirms test apparatus)' do
      # Inverse of the previous case: state captured in the factory block's
      # closure (NOT inside a wrapper instance) is expected to persist. If
      # this stopped working, the isolation tests above would be meaningless.
      factory_call_count = 0
      otto.register_handler_wrapper do |_rd, inner|
        factory_call_count += 1
        inner
      end

      3.times { otto.call(mock_rack_env(method: 'GET', path: '/')) }

      expect(factory_call_count).to eq(3)
    end

    it 'observes the current env for each request, not a stale env' do
      seen_envs = []
      otto.register_handler_wrapper do |_rd, inner|
        capture = Class.new do
          define_method(:initialize) { |i| @inner = i }
          define_method(:call) do |env, extra = {}|
            seen_envs << { path: env['PATH_INFO'], qs: env['QUERY_STRING'], hdr: env['HTTP_X_TAG'] }
            @inner.call(env, extra)
          end
        end
        capture.new(inner)
      end

      otto.call(mock_rack_env(method: 'GET', path: '/', headers: { 'X-Tag' => 'first' }))
      otto.call(mock_rack_env(method: 'GET', path: '/show/42', headers: { 'X-Tag' => 'second' }))

      expect(seen_envs.length).to eq(2)
      expect(seen_envs[0][:path]).to eq('/')
      expect(seen_envs[0][:hdr]).to eq('first')
      expect(seen_envs[1][:path]).to eq('/show/42')
      expect(seen_envs[1][:hdr]).to eq('second')
    end

    it 'gives each concurrent request a distinct wrapper instance' do
      # Best-effort: 4 threads x 10 requests. Collect object_ids under a
      # mutex; require strictly distinct ids. Accidental memoization
      # (e.g. caching the constructed wrapper) would collapse the set.
      ids = Set.new
      mu = Mutex.new

      otto.register_handler_wrapper do |_rd, inner|
        w = recording_wrapper_class.new(inner, :concurrent, [])
        mu.synchronize { ids << w.object_id }
        w
      end

      threads = Array.new(4) do
        Thread.new do # rubocop:disable ThreadSafety/NewThread
          10.times { otto.call(mock_rack_env(method: 'GET', path: '/')) }
        end
      end
      threads.each(&:join)

      expect(ids.size).to eq(40)
    end
  end

  describe 'zero-overhead path' do
    let(:route_def) { Otto::RouteDefinition.new('GET', '/test', 'TestApp.index') }

    it 'returns the input handler unchanged when no wrappers are registered' do
      base_handler = Otto::RouteHandlers::ClassMethodHandler.new(route_def)
      result = Otto::RouteHandlers::HandlerFactory.apply_handler_wrappers(base_handler, route_def, otto)

      expect(result).to equal(base_handler)
    end

    it 'returns the input handler when otto_instance is nil' do
      base_handler = Otto::RouteHandlers::ClassMethodHandler.new(route_def)
      result = Otto::RouteHandlers::HandlerFactory.apply_handler_wrappers(base_handler, route_def, nil)

      expect(result).to equal(base_handler)
    end

    it 'create_handler still produces the expected handler type without wrappers' do
      handler = Otto::RouteHandlers::HandlerFactory.create_handler(route_def, otto)

      # With otto_instance, the outermost object is RouteAuthWrapper (no
      # consumer wrappers); its wrapped_handler is the base handler class.
      expect(handler).to be_a(Otto::Security::Authentication::RouteAuthWrapper)
      expect(handler.wrapped_handler).to be_a(Otto::RouteHandlers::ClassMethodHandler)
    end

    it 'does not invoke any factory blocks when no wrappers are registered' do
      # Sanity check that the early-return on factory.rb:47 fires: register
      # nothing, then ensure handler_wrappers is empty for the request path.
      expect(otto.handler_wrappers).to be_empty
      status, = otto.call(mock_rack_env(method: 'GET', path: '/'))
      expect(status).to eq(200)
    end
  end
end
