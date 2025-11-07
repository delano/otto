# spec/otto/middleware_args_edge_cases_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Middleware Args Edge Cases' do
  let(:otto) { Otto.new }
  let(:security_config) { otto.security_config }

  # Mock middleware classes for testing
  let(:security_middleware) do
    Class.new do
      attr_reader :app, :security_config, :custom_args, :options

      def initialize(app, *args, **options)
        @app = app
        # Detect if first arg is security config
        if args.first.is_a?(Otto::Security::Config)
          @security_config = args.shift
          @custom_args = args
        else
          @custom_args = args
        end
        @options = options
      end

      def call(env)
        @app.call(env)
      end
    end
  end

  let(:regular_middleware) do
    Class.new do
      attr_reader :app, :args, :options

      def initialize(app, *args, **options)
        @app = app
        @args = args
        @options = options
      end

      def call(env)
        @app.call(env)
      end
    end
  end

  let(:proc_middleware) do
    lambda do |app|
      Class.new do
        attr_reader :app

        def initialize(app)
          @app = app
        end

        def call(env)
          @app.call(env)
        end
      end.new(app)
    end
  end

  describe 'security config injection behavior' do
    before do
      stub_const('Otto::Security::Middleware::CSRFMiddleware', security_middleware)
      stub_const('Otto::Security::Middleware::ValidationMiddleware', security_middleware)
      stub_const('RegularMiddleware', regular_middleware)
    end

    it 'injects security_config into known security middleware' do
      otto.middleware.add(Otto::Security::Middleware::CSRFMiddleware)

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, security_config)

      expect(app.security_config).to eq(security_config)
      expect(app.custom_args).to be_empty
    end

    it 'does not inject security_config into regular middleware' do
      otto.middleware.add(RegularMiddleware)

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, security_config)

      expect(app.args).to be_empty
      expect(app).not_to respond_to(:security_config)
    end

    it 'injects security_config before custom args for security middleware' do
      otto.middleware.add(Otto::Security::Middleware::ValidationMiddleware, 'custom_arg', option: 'value')

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, security_config)

      expect(app.security_config).to eq(security_config)
      expect(app.custom_args).to eq(['custom_arg'])
      expect(app.options).to eq(option: 'value')
    end

    it 'preserves custom args for regular middleware' do
      otto.middleware.add(RegularMiddleware, 'arg1', 'arg2', option: 'value')

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, security_config)

      expect(app.args).to eq(%w[arg1 arg2])
      expect(app.options).to eq(option: 'value')
    end

    it 'handles proc-based middleware correctly' do
      otto.middleware.add(proc_middleware)

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, security_config)

      # With IP Privacy middleware always present, it wraps the base app first
      expect(app.app).to be_a(Otto::Security::Middleware::IPPrivacyMiddleware)
      expect(app.app.instance_variable_get(:@app)).to eq(base_app)
    end
  end

  describe 'middleware_needs_config? helper method' do
    let(:middleware_stack) { Otto::Core::MiddlewareStack.new }

    it 'identifies Otto::Security::Middleware::CSRFMiddleware as needing config' do
      result = middleware_stack.send(:middleware_needs_config?, Otto::Security::Middleware::CSRFMiddleware)
      expect(result).to be true
    end

    it 'identifies Otto::Security::Middleware::ValidationMiddleware as needing config' do
      result = middleware_stack.send(:middleware_needs_config?, Otto::Security::Middleware::ValidationMiddleware)
      expect(result).to be true
    end

    it 'identifies Otto::Security::Middleware::RateLimitMiddleware as needing config' do
      result = middleware_stack.send(:middleware_needs_config?, Otto::Security::Middleware::RateLimitMiddleware)
      expect(result).to be true
    end

    # Removed: AuthenticationMiddleware no longer exists - authentication is handled by RouteAuthWrapper

    it 'identifies regular middleware as not needing config' do
      custom_middleware = Class.new
      result = middleware_stack.send(:middleware_needs_config?, custom_middleware)
      expect(result).to be false
    end
  end

  describe 'complex middleware chain scenarios' do
    before do
      stub_const('Otto::Security::Middleware::CSRFMiddleware', security_middleware)
      stub_const('RegularMiddleware', regular_middleware)
    end

    it 'builds chain with mixed middleware types correctly' do
      otto.middleware.add(RegularMiddleware, 'regular_arg')
      otto.middleware.add(Otto::Security::Middleware::CSRFMiddleware, 'csrf_arg')

      base_app = ->(_env) { [200, {}, ['base']] }

      # Build the middleware chain
      app = otto.middleware.wrap(base_app, security_config)

      # The outermost middleware should be CSRFMiddleware (added last, wraps the previous ones)
      expect(app).to be_a(Otto::Security::Middleware::CSRFMiddleware)
      expect(app.custom_args).to eq(['csrf_arg'])
    end

    it 'handles empty args correctly' do
      otto.middleware.add(Otto::Security::Middleware::CSRFMiddleware)
      otto.middleware.add(RegularMiddleware)

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, security_config)

      expect(app).to be_a(regular_middleware)
      expect(app.args).to be_empty
    end

    it 'handles middleware with only keyword arguments' do
      otto.middleware.add(RegularMiddleware, option1: 'value1', option2: 'value2')

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, security_config)

      expect(app.args).to be_empty
      expect(app.options).to eq(option1: 'value1', option2: 'value2')
    end
  end

  describe 'error handling in middleware building' do
    let(:faulty_middleware) do
      Class.new do
        def initialize(_app, *_args, **_options)
          raise StandardError, 'Middleware initialization failed'
        end
      end
    end

    it 'propagates middleware initialization errors' do
      otto.middleware.add(faulty_middleware)

      base_app = ->(_env) { [200, {}, ['base']] }

      expect do
        otto.middleware.wrap(base_app, security_config)
      end.to raise_error(StandardError, 'Middleware initialization failed')
    end
  end

  describe 'nil security_config handling' do
    before do
      stub_const('Otto::Security::Middleware::CSRFMiddleware', security_middleware)
    end

    it 'handles nil security_config gracefully' do
      otto.middleware.add(Otto::Security::Middleware::CSRFMiddleware, 'custom_arg')

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, nil)

      # Should still work, just without security config injection
      expect(app.custom_args).to eq(['custom_arg'])
      expect(app.security_config).to be_nil
    end

    it 'handles regular middleware with nil security_config' do
      otto.middleware.add(regular_middleware, 'arg')

      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, nil)

      expect(app.args).to eq(['arg'])
    end
  end

  describe 'middleware order preservation' do
    before do
      stub_const('Middleware1', Class.new(regular_middleware))
      stub_const('Middleware2', Class.new(regular_middleware))
      stub_const('Middleware3', Class.new(regular_middleware))
    end

    it 'preserves middleware order for execution (last added is outermost)' do
      otto.middleware.add(Middleware1)
      otto.middleware.add(Middleware2)
      otto.middleware.add(Middleware3)

      # Middleware list should be in addition order (IPPrivacyMiddleware is always first)
      expect(otto.middleware.middleware_list).to eq([Otto::Security::Middleware::IPPrivacyMiddleware, Middleware1, Middleware2, Middleware3])

      # But execution follows standard Rack behavior (last added wraps the others)
      base_app = ->(_env) { [200, {}, ['base']] }
      app = otto.middleware.wrap(base_app, security_config)

      # The outermost middleware should be the last one added
      expect(app).to be_a(Middleware3)
    end
  end
end
