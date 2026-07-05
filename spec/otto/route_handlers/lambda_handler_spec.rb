# spec/otto/route_handlers/lambda_handler_spec.rb
#
# frozen_string_literal: true

require_relative '../../spec_helper'

# Acceptance spec for the Lambda/Inline route handler (issue #41).
#
# LambdaHandler resolves a pre-registered proc O(1) by name from
# otto.config[:lambda_handlers] (no eval, no dynamic constants) and reuses the
# BaseHandler#call pipeline (setup_request_response, response-type dispatch,
# centralized error handling). These tests drive the handler directly and prove:
#   - HandlerFactory dispatches :lambda RouteDefinitions to LambdaHandler (AC#2)
#   - the proc is invoked with (req, res, extra_params) (AC#4)
#   - every response type is honored (AC#5)
#   - a missing/uncallable handler fails with a clear, named error and never
#     executes arbitrary code (AC#7, AC#8)
#
# NOTE ON CONTEXTS: the lambda registry lives ON the Otto instance
# (otto.config[:lambda_handlers]); a handler built WITHOUT an otto_instance has
# an empty registry by design, so happy-path resolution is exercised in the
# integrated (otto present) context. The direct (no-otto) context is exercised
# for its supported behavior: the base's constant-resolution guards hold and the
# failure surfaces as a clean local 500 rather than a constant/nil crash.
RSpec.describe Otto::RouteHandlers::LambdaHandler do
  let(:route_definition) do
    Otto::RouteDefinition.new('GET', '/ping', '&health_check')
  end

  # Build a real Otto with a real, frozen lambda registry (never stub
  # otto.config -- verify_partial_doubles + the real registry is the point).
  def build_otto(handlers)
    routes_file = create_test_routes_file('lambda_handler.txt', ['GET /ping &health_check'])
    Otto.new(routes_file, lambda_handlers: handlers)
  end

  # Construct a LambdaHandler for `target_def`, backed by an otto whose registry
  # maps 'health_check' => proc_obj, and drive #call. Returns the Rack triple.
  def run_lambda(target_def, proc_obj, path: '/ping', headers: {}, extra: {})
    otto = build_otto('health_check' => proc_obj)
    rd = Otto::RouteDefinition.new('GET', path, target_def)
    handler = described_class.new(rd, otto)
    env = mock_rack_env(method: 'GET', path: path, headers: headers)
    handler.call(env, extra)
  end

  describe 'factory dispatch (AC#2)' do
    it 'routes a :lambda RouteDefinition to a LambdaHandler in the direct context' do
      handler = Otto::RouteHandlers::HandlerFactory.create_handler(route_definition)

      expect(handler).to be_a(described_class)
    end

    it 'wraps the LambdaHandler in a RouteAuthWrapper in the integrated context' do
      otto = build_otto('health_check' => ->(_req, _res, _extra) {})

      handler = Otto::RouteHandlers::HandlerFactory.create_handler(route_definition, otto)

      expect(handler).to be_a(Otto::Security::Authentication::RouteAuthWrapper)
      expect(handler.wrapped_handler).to be_a(described_class)
    end
  end

  describe 'invocation contract (AC#4)' do
    it 'invokes the registered proc with (req, res, extra_params)' do
      seen = []
      proc_obj = lambda do |req, res, extra|
        seen = [req, res, extra]
        res.write('ok')
        nil
      end
      otto = build_otto('health_check' => proc_obj)
      handler = described_class.new(route_definition, otto)

      handler.call(mock_rack_env(path: '/ping'), { id: '7' })

      expect(seen[0]).to respond_to(:params)   # a request object
      expect(seen[1]).to respond_to(:write)    # a response object
      expect(seen[2]).to include(id: '7')      # extra_params reached the 3rd arg
    end

    it 'reuses the BaseHandler pipeline: setup exposes route metadata on env' do
      otto = build_otto('health_check' => ->(_req, _res, _extra) {})
      handler = described_class.new(route_definition, otto)
      env = mock_rack_env(path: '/ping')

      handler.call(env)

      # A standalone #call would leave these unset; their presence proves
      # setup_request_response ran (pipeline reuse, not a bypass).
      expect(env['otto.route_definition']).to eq(route_definition)
      expect(env['otto.route_options']).to eq(route_definition.options)
    end
  end

  describe 'response types (AC#5)' do
    it 'json: serializes a Hash return value' do
      status, headers, body = run_lambda('&health_check response=json',
                                         ->(_req, _res, _extra) { { ok: true } })

      expect(status).to eq(200)
      expect(headers['Content-Type']).to eq('application/json')
      expect(JSON.parse(body.first)).to eq('ok' => true)
    end

    it 'json: wraps a String return value under data' do
      _status, _headers, body = run_lambda('&health_check response=json',
                                           ->(_req, _res, _extra) { 'hello' })

      expect(JSON.parse(body.first)).to eq('success' => true, 'data' => 'hello')
    end

    it 'json: treats a nil return value as success' do
      _status, _headers, body = run_lambda('&health_check response=json',
                                           ->(_req, _res, _extra) { nil })

      expect(JSON.parse(body.first)).to eq('success' => true)
    end

    it 'redirect: a returned String path becomes a 302 Location' do
      status, headers, = run_lambda('&health_check response=redirect',
                                    ->(_req, _res, _extra) { '/next' })

      expect(status).to eq(302)
      expect(headers['Location']).to eq('/next')
    end

    it 'view: a returned String becomes an HTML body' do
      _status, headers, body = run_lambda('&health_check response=view',
                                          ->(_req, _res, _extra) { '<h1>Hi</h1>' })

      expect(headers['Content-Type']).to eq('text/html')
      expect(body.first).to eq('<h1>Hi</h1>')
    end

    it 'auto: a Hash is auto-detected as JSON' do
      _status, headers, = run_lambda('&health_check response=auto',
                                     ->(_req, _res, _extra) { { ok: true } })

      expect(headers['Content-Type']).to eq('application/json')
    end

    it 'auto: a path-like String is auto-detected as a redirect' do
      status, headers, = run_lambda('&health_check response=auto',
                                    ->(_req, _res, _extra) { '/go' })

      expect(status).to eq(302)
      expect(headers['Location']).to eq('/go')
    end

    it 'default: honors what the proc writes and ignores the return value' do
      status, _headers, body = run_lambda('&health_check',
                                          lambda do |_req, res, _extra|
                                            res.write('written')
                                            { ignored: true } # return value ignored under default
                                          end)

      expect(status).to eq(200)
      expect(body.first).to eq('written')
    end
  end

  describe 'missing / invalid handlers (AC#7, AC#8)' do
    it 'raises a clear, named ArgumentError when the handler is absent from the registry' do
      otto = build_otto({}) # empty registry; route names &health_check
      handler = described_class.new(route_definition, otto)

      expect do
        handler.call(mock_rack_env(path: '/ping'))
      end.to raise_error(ArgumentError) do |err|
        expect(err.message).to match(/health_check/)              # names the handler
        expect(err.message).to match(/not registered|not callable/) # states the reason
      end
    end

    it 'annotates env with a Lambda handler name and duration on failure (handler_name guard)' do
      otto = build_otto({})
      handler = described_class.new(route_definition, otto)
      env = mock_rack_env(path: '/ping')

      begin
        handler.call(env)
      rescue ArgumentError
        # expected -- integrated context re-raises for the centralized handler
      end

      # Proves #handler_name is derived from the route, not target_class.name
      # (which would be nil.name -> NoMethodError). No crash-on-nil occurred.
      expect(env['otto.handler']).to match(/Lambda/)
      expect(env['otto.handler_duration']).to be_a(Integer)
    end

    it 'rejects a non-callable registry value at construction (fail fast)' do
      routes_file = create_test_routes_file('lambda_handler.txt', ['GET /ping &health_check'])

      # The registry is validated during Otto.new, so an uncallable value never
      # survives to be dispatched -- the clear error surfaces synchronously.
      expect do
        Otto.new(routes_file, lambda_handlers: { 'health_check' => 'nope' })
      end.to raise_error(ArgumentError, /not callable/)
    end

    it 'does not execute arbitrary code: a source-looking key is an inert, absent lookup (AC#8)' do
      executed = []
      # Registry knows only 'safe'; the route names a key that LOOKS like code.
      routes_file = create_test_routes_file('lambda_handler.txt', ["GET /x &system('boom') response=json"])
      otto = Otto.new(routes_file, lambda_handlers: { 'safe' => ->(_r, _s, _e) { executed << :ran } })
      rd = Otto::RouteDefinition.new('GET', '/x', "&system('boom') response=json")
      handler = described_class.new(rd, otto)

      expect(Kernel).not_to receive(:system)
      expect do
        handler.call(mock_rack_env(path: '/x'))
      end.to raise_error(ArgumentError, %r{system\('boom'\)})
      # The key was never eval'd, never const-resolved, never dispatched.
      expect(executed).to be_empty
    end
  end

  describe 'direct vs integrated context symmetry' do
    it 'direct (no otto_instance): guards hold and an unresolved handler yields a clean local 500' do
      # No otto -> empty registry by design. The base constant-resolution guards
      # (target_class -> nil, handler_name override) must hold so this fails as a
      # clean local 500, NOT an "Invalid class name format" or nil.name crash.
      rd = Otto::RouteDefinition.new('GET', '/ping', '&health_check response=json')
      handler = described_class.new(rd) # no otto_instance
      env = mock_rack_env(path: '/ping', headers: { 'Accept' => 'application/json' })

      status, headers, body = handler.call(env)

      expect(status).to eq(500)
      expect(headers['content-type']).to eq('application/json')
      # Generic error body -- details are logged, never leaked (AC#8).
      expect(JSON.parse(body.first)['error']).to eq('Internal Server Error')
    end

    it 'integrated: an exception raised inside the proc propagates with the handler annotated' do
      otto = build_otto('health_check' => ->(*) { raise StandardError, 'boom' })
      handler = described_class.new(route_definition, otto)
      env = mock_rack_env(path: '/ping')

      expect do
        handler.call(env)
      end.to raise_error(StandardError, 'boom')

      # The centralized error handler receives a named handler, not target_class.name.
      expect(env['otto.handler']).to match(/Lambda/)
    end
  end
end
