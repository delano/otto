# frozen_string_literal: true

require 'spec_helper'

# Acceptance coverage for issue #41, AC#3 & AC#8:
# Otto validates the :lambda_handlers registry synchronously during
# construction, accepting only pre-registered callables with a compatible
# arity, raising a clear ArgumentError (naming the offending handler) for
# anything else, and storing the result frozen at otto.config[:lambda_handlers].
#
# NOTE (per test plan): never stub otto.config / otto.option. Always drive a
# real Otto built with `lambda_handlers:` so verify_partial_doubles and the
# real frozen registry are exercised.
RSpec.describe 'Otto lambda_handlers configuration (issue #41 AC#3/AC#8)' do
  # A minimal, lambda-free route file. The registry is validated by the
  # constructor independently of the routes, so a plain controller route keeps
  # these examples focused on registry validation only.
  let(:routes_file) { create_test_routes_file('test_routes_lambda_cfg.txt', ['GET /health TestApp.index']) }

  # Build a real Otto with the given handler registry.
  def build(handlers)
    Otto.new(routes_file, lambda_handlers: handlers)
  end

  describe 'accepted callables (valid arities)' do
    it 'accepts a 3-arity lambda ->(req, res, extra) {}' do
      expect { build('ok' => ->(_a, _b, _c) {}) }.not_to raise_error
    end

    it 'accepts a splat lambda ->(*a) {} (arity -1)' do
      handler = ->(*_a) {}
      expect(handler.arity).to eq(-1)
      expect { build('ok' => handler) }.not_to raise_error
    end

    it 'accepts a one-required-plus-splat lambda ->(a, *b) {} (arity -2)' do
      handler = ->(_a, *_b) {}
      expect(handler.arity).to eq(-2)
      expect { build('ok' => handler) }.not_to raise_error
    end

    it 'accepts an optional-tail lambda ->(a, b, c = 1) {} (arity -3)' do
      handler = ->(_a, _b, _c = 1) {}
      expect(handler.arity).to eq(-3)
      expect { build('ok' => handler) }.not_to raise_error
    end

    it 'accepts a non-lambda proc of arity 3 (proc {|a, b, c| })' do
      handler = proc { |_a, _b, _c| }
      expect(handler.arity).to eq(3)
      expect(handler.lambda?).to be(false)
      expect { build('ok' => handler) }.not_to raise_error
    end

    it 'accepts a registry of several valid handlers together' do
      expect do
        build(
          'a' => ->(_req, _res, _extra) {},
          'b' => ->(*_args) {},
          'c' => proc { |_req, _res, _extra| }
        )
      end.not_to raise_error
    end
  end

  describe 'rejected optional-arg lambdas that cannot take 3 positionals (BUG B)' do
    # These forms have a negative arity but cannot actually accept 3 positional
    # args, so they must fail fast at Otto.new instead of raising "wrong number
    # of arguments" at request time.
    it 'rejects ->(a = 1) {} (arity -1, accepts 0..1) naming the handler' do
      handler = ->(_a = 1) {}
      expect(handler.arity).to eq(-1)
      expect { build('bad' => handler) }.to raise_error(ArgumentError, /bad/)
    end

    it 'rejects ->(a, b = 1) {} (arity -2, accepts 1..2) naming the handler' do
      handler = ->(_a, _b = 1) {}
      expect(handler.arity).to eq(-2)
      expect { build('bad' => handler) }.to raise_error(ArgumentError, /bad/)
    end
  end

  describe 'non-Proc callable objects (BUG A: no #arity required)' do
    # An object with `def call(req, res, extra)` responds to #call but not
    # #arity. It must be accepted without a NoMethodError, and rejected with a
    # clear named ArgumentError when its #call takes the wrong number of args.
    let(:valid_callable_class) do
      Class.new do
        def call(_req, _res, _extra); end
      end
    end

    let(:wrong_arity_callable_class) do
      Class.new do
        def call(_only_one); end
      end
    end

    it 'accepts a callable object whose #call takes (req, res, extra)' do
      handler = valid_callable_class.new
      expect(handler).not_to respond_to(:arity)
      expect { build('ok' => handler) }.not_to raise_error
    end

    it 'rejects a callable object whose #call takes the wrong number of args' do
      handler = wrong_arity_callable_class.new
      expect(handler).not_to respond_to(:arity)
      expect { build('bad' => handler) }.to raise_error(ArgumentError, /bad/)
    end
  end

  describe 'rejected fixed arities (clear ArgumentError naming the handler)' do
    it 'rejects a zero-arity lambda ->{} (arity 0)' do
      expect { build('bad' => -> {}) }.to raise_error(ArgumentError, /bad/)
    end

    it 'rejects a 1-arity lambda ->(a) {} (arity 1)' do
      expect { build('bad' => ->(_a) {}) }.to raise_error(ArgumentError, /bad/)
    end

    it 'rejects a 2-arity lambda ->(a, b) {} (arity 2)' do
      expect { build('bad' => ->(_a, _b) {}) }.to raise_error(ArgumentError, /bad/)
    end

    it 'rejects a 4-arity lambda ->(a, b, c, d) {} (arity 4)' do
      expect { build('bad' => ->(_a, _b, _c, _d) {}) }.to raise_error(ArgumentError, /bad/)
    end

    it 'names the offending handler key and cites arity in the message' do
      error = nil
      begin
        build('bad' => ->(_a) {})
      rescue ArgumentError => e
        error = e
      end
      expect(error).to be_a(ArgumentError)
      expect(error.message).to match(/bad/)
      expect(error.message).to match(/arity/)
    end
  end

  describe 'rejected non-callable values (message mentions callable)' do
    def capture_build_error(handlers)
      build(handlers)
      nil
    rescue ArgumentError => e
      e
    end

    it 'rejects a String value naming the handler and mentioning callable' do
      error = capture_build_error('bad' => 'a string')
      expect(error).to be_a(ArgumentError)
      expect(error.message).to match(/bad/)
      expect(error.message).to match(/callable/)
    end

    it 'rejects an Integer value naming the handler and mentioning callable' do
      error = capture_build_error('bad' => 42)
      expect(error).to be_a(ArgumentError)
      expect(error.message).to match(/bad/)
      expect(error.message).to match(/callable/)
    end

    it 'rejects a plain Object value naming the handler and mentioning callable' do
      error = capture_build_error('bad' => Object.new)
      expect(error).to be_a(ArgumentError)
      expect(error.message).to match(/bad/)
      expect(error.message).to match(/callable/)
    end
  end

  describe 'validation happens during Otto.new, before any request is served' do
    it 'raises synchronously from the constructor (no otto.call needed)' do
      expect { build('bad' => -> {}) }.to raise_error(ArgumentError)
    end

    it 'does not partially construct — a valid handler alongside a bad one still raises' do
      expect do
        build('good' => ->(_a, _b, _c) {}, 'bad' => ->(_a) {})
      end.to raise_error(ArgumentError, /bad/)
    end
  end

  describe 'stored registry is exposed and frozen (AC#8)' do
    it 'exposes the registry at otto.config[:lambda_handlers]' do
      handler = ->(_a, _b, _c) {}
      otto = build('health_check' => handler)
      expect(otto.config[:lambda_handlers]).to be_a(Hash)
      expect(otto.config[:lambda_handlers]['health_check']).to be(handler)
    end

    it 'freezes the stored registry' do
      otto = build('health_check' => ->(_a, _b, _c) {})
      expect(otto.config[:lambda_handlers]).to be_frozen
    end

    it 'raises FrozenError on attempted mutation of the registry' do
      otto = build('health_check' => ->(_a, _b, _c) {})
      expect { otto.config[:lambda_handlers]['x'] = -> {} }.to raise_error(FrozenError)
    end
  end

  describe 'key normalization (Symbol keys resolve like String keys)' do
    # Route targets are always Strings parsed from the route file, so a handler
    # registered under a Symbol key must be reachable by its String name.
    it 'normalizes Symbol keys to Strings in the stored registry' do
      handler = ->(_a, _b, _c) {}
      otto = build(health_check: handler)
      expect(otto.config[:lambda_handlers]['health_check']).to be(handler)
    end

    it 'preserves String keys as-is' do
      handler = ->(_a, _b, _c) {}
      otto = build('health_check' => handler)
      expect(otto.config[:lambda_handlers]['health_check']).to be(handler)
    end

    it 'rejects a blank handler name' do
      expect { build('' => ->(_a, _b, _c) {}) }
        .to raise_error(ArgumentError, /blank/)
    end

    it 'rejects a whitespace-only handler name' do
      expect { build('   ' => ->(_a, _b, _c) {}) }
        .to raise_error(ArgumentError, /blank/)
    end

    it 'raises when a Symbol and String key collide after normalization' do
      expect { build(health_check: ->(_a, _b, _c) {}, 'health_check' => ->(_a, _b, _c) {}) }
        .to raise_error(ArgumentError, /more than once/)
    end
  end

  describe "does not mutate the caller's Hash" do
    it 'leaves the input Hash unfrozen and independent of the stored registry' do
      input = { 'health_check' => ->(_a, _b, _c) {} }
      otto = build(input)
      expect(input).not_to be_frozen
      expect(input).not_to be(otto.config[:lambda_handlers])
      # Caller can still mutate their own object without a FrozenError.
      expect { input['other'] = ->(_a, _b, _c) {} }.not_to raise_error
    end
  end

  describe 'empty / absent registry' do
    it 'defaults to a frozen empty Hash when no :lambda_handlers option is given' do
      otto = Otto.new(routes_file)
      expect(otto.config[:lambda_handlers]).to eq({})
      expect(otto.config[:lambda_handlers]).to be_frozen
    end

    it 'accepts an explicit empty Hash without error' do
      expect { build({}) }.not_to raise_error
      expect(build({}).config[:lambda_handlers]).to eq({})
    end
  end
end
