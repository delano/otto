require 'spec_helper'

RSpec.describe 'Middleware Stack Synchronization' do
  let(:otto) { Otto.new }
  let(:test_middleware1) { Class.new }
  let(:test_middleware2) { Class.new }

  describe 'legacy and new stack synchronization' do
    it 'adds middleware to both legacy and new stacks via use method' do
      otto.use(test_middleware1)

      # Should be in legacy middleware_stack
      expect(otto.middleware_stack).to include(test_middleware1)

      # Should be in new middleware stack
      expect(otto.middleware.includes?(test_middleware1)).to be true
      expect(otto.middleware.middleware_list).to include(test_middleware1)
    end

    it 'maintains order consistency between stacks' do
      otto.use(test_middleware1)
      otto.use(test_middleware2)

      # Legacy stack order
      expect(otto.middleware_stack).to eq([test_middleware1, test_middleware2])

      # New stack order
      expect(otto.middleware.middleware_list).to eq([test_middleware1, test_middleware2])
    end

    it 'handles middleware added via security methods' do
      otto.enable_csrf_protection!

      # Should be in both stacks
      expect(otto.middleware_stack).to include(Otto::Security::CSRFMiddleware)
      expect(otto.middleware.includes?(Otto::Security::CSRFMiddleware)).to be true
    end

    it 'prevents duplicates in legacy stack when security methods called multiple times' do
      otto.enable_csrf_protection!
      otto.enable_csrf_protection!

      csrf_count = otto.middleware_stack.count(Otto::Security::CSRFMiddleware)
      expect(csrf_count).to eq(1)
    end

    it 'prevents duplicates in new stack when security methods called multiple times' do
      otto.enable_csrf_protection!
      otto.enable_csrf_protection!

      expect(otto.middleware.middleware_list.count(Otto::Security::CSRFMiddleware)).to eq(1)
    end
  end

  describe 'middleware detection synchronization' do
    it 'middleware_enabled? checks both stacks' do
      # Add to new stack only
      otto.middleware.add(test_middleware1)

      # Should detect middleware in new stack
      expect(otto.send(:middleware_enabled?, test_middleware1)).to be true
    end

    it 'middleware_enabled? checks legacy stack' do
      # Add to legacy stack only
      otto.middleware_stack << test_middleware1

      # Should detect middleware in legacy stack
      expect(otto.send(:middleware_enabled?, test_middleware1)).to be true
    end

    it 'middleware_enabled? returns false when middleware not in either stack' do
      expect(otto.send(:middleware_enabled?, test_middleware1)).to be false
    end

    it 'prevents adding security middleware when already in new stack' do
      # Add directly to new stack
      otto.middleware.add(Otto::Security::CSRFMiddleware)

      # Try to enable via security method
      otto.enable_csrf_protection!

      # Should not duplicate in legacy stack
      expect(otto.middleware_stack.count(Otto::Security::CSRFMiddleware)).to eq(0)
    end
  end

  describe 'middleware execution order' do
    let(:base_app) { ->(env) { [200, {}, ['base']] } }
    let(:mock_middleware) do
      Class.new do
        attr_reader :app, :security_config

        def initialize(app, security_config = nil)
          @app = app
          @security_config = security_config
        end

        def call(env)
          @app.call(env)
        end
      end
    end

    before do
      stub_const('TestMiddleware', mock_middleware)
    end

    it 'uses new middleware stack when available' do
      otto.middleware.add(TestMiddleware)

      # Mock handle_request to return base_app
      allow(otto).to receive(:handle_request).and_return(base_app)

      # Call should use new middleware stack
      result = otto.call({})
      expect(result).to eq([200, {}, ['base']])
    end

    it 'falls back to legacy stack when new stack is empty' do
      otto.middleware_stack << TestMiddleware

      # Mock handle_request
      allow(otto).to receive(:handle_request).and_return(base_app)

      # Should work with legacy stack
      result = otto.call({})
      expect(result).to eq([200, {}, ['base']])
    end

    it 'prefers new stack over legacy when both have middleware' do
      # Add different middleware to each stack
      otto.middleware_stack << Class.new
      otto.middleware.add(TestMiddleware)

      # Mock handle_request
      allow(otto).to receive(:handle_request).and_return(base_app)

      # Should use new stack (TestMiddleware should be used)
      result = otto.call({})
      expect(result).to eq([200, {}, ['base']])
    end
  end

  describe 'security configuration integration' do
    it 'passes security config to new middleware stack' do
      # Add security middleware via configurator
      otto.security.enable_csrf_protection!

      # Both stacks should have the middleware
      expect(otto.middleware_stack).to include(Otto::Security::CSRFMiddleware)
      expect(otto.middleware.includes?(Otto::Security::CSRFMiddleware)).to be true
    end

    it 'maintains security config consistency' do
      # Configure via security configurator
      otto.security.configure(
        csrf_protection: true,
        trusted_proxies: ['127.0.0.1']
      )

      # Security config should be updated
      expect(otto.security_config.csrf_enabled?).to be true
      expect(otto.security_config.trusted_proxy?('127.0.0.1')).to be true

      # Middleware should be in both stacks
      expect(otto.middleware_stack).to include(Otto::Security::CSRFMiddleware)
      expect(otto.middleware.includes?(Otto::Security::CSRFMiddleware)).to be true
    end
  end

  describe 'edge cases' do
    it 'handles empty middleware stacks gracefully' do
      # Mock handle_request
      base_app = ->(env) { [200, {}, ['base']] }
      allow(otto).to receive(:handle_request).and_return(base_app)

      result = otto.call({})
      expect(result).to eq([200, {}, ['base']])
    end

    it 'handles middleware with custom arguments in both stacks' do
      otto.use(test_middleware1, 'arg1', option: 'value')

      # Legacy stack should have the middleware
      expect(otto.middleware_stack).to include(test_middleware1)

      # New stack should have middleware with details
      details = otto.middleware.middleware_details
      middleware_detail = details.find { |d| d[:middleware] == test_middleware1 }
      expect(middleware_detail[:args]).to eq(['arg1'])
      expect(middleware_detail[:options]).to eq(option: 'value')
    end
  end
end
