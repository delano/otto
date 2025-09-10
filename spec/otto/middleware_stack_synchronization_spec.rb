require 'spec_helper'

RSpec.describe 'Middleware Stack Synchronization' do
  let(:otto) { Otto.new }
  let(:test_middleware1) { Class.new }
  let(:test_middleware2) { Class.new }

  describe 'middleware synchronization' do
    it 'adds middleware to middleware stack via use method' do
      otto.use(test_middleware1)

      # Should be in middleware stack
      expect(otto.middleware.middleware_list).to include(test_middleware1)
    end

    it 'maintains order of middleware stack' do
      otto.use(test_middleware1)
      otto.use(test_middleware2)

      # Stack order
      expect(otto.middleware.middleware_list).to eq([test_middleware1, test_middleware2])
    end

    it 'handles middleware added via security methods' do
      otto.enable_csrf_protection!

      # Should be in middleware stack
      expect(otto.middleware.includes?(Otto::Security::CSRFMiddleware)).to be true
    end

    it 'prevents duplicates when security methods called multiple times' do
      otto.enable_csrf_protection!
      otto.enable_csrf_protection!

      expect(otto.middleware.middleware_list.count(Otto::Security::CSRFMiddleware)).to eq(1)
    end
  end

  describe 'middleware detection' do
    it 'checks for existing middleware' do
      # Add to new stack
      otto.middleware.add(test_middleware1)

      # Should detect middleware
      expect(otto.middleware.includes?(test_middleware1)).to be true
    end

    it 'returns false when middleware not in stack' do
      expect(otto.middleware.includes?(test_middleware1)).to be false
    end

    it 'prevents adding duplicate security middleware' do
      # Add directly to new stack
      otto.middleware.add(Otto::Security::CSRFMiddleware)

      # Try to enable via security method
      otto.enable_csrf_protection!

      # Should not duplicate
      expect(otto.middleware.middleware_list.count(Otto::Security::CSRFMiddleware)).to eq(1)
    end
  end

  # Define test middleware class properly
  class ::TestExecutionMiddleware
    attr_reader :app, :security_config

    def initialize(app, security_config = nil)
      @app = app
      @security_config = security_config
    end

    def call(env)
      @app.call(env)
    end
  end

  describe 'middleware execution' do
    let(:base_app) { ->(env) { [200, {}, ['base']] } }

    it 'uses middleware stack when available' do
      otto.middleware.add(TestExecutionMiddleware)

      # Mock handle_request to return the result of calling base_app
      allow(otto).to receive(:handle_request).and_return([200, {}, ['base']])

      # Call should use middleware stack
      result = otto.call({})
      expect(result).to eq([200, {}, ['base']])
    end

    it 'handles empty middleware stack' do
      # Mock handle_request
      allow(otto).to receive(:handle_request).and_return([200, {}, ['base']])

      # Should work with empty stack
      result = otto.call({})
      expect(result).to eq([200, {}, ['base']])
    end
  end

  describe 'security configuration' do
    it 'configures security middleware' do
      # Add security middleware via configurator
      otto.security.enable_csrf_protection!

      # Middleware should be in stack
      expect(otto.middleware.includes?(Otto::Security::CSRFMiddleware)).to be true
    end

    it 'maintains security configuration' do
      # Configure via security configurator
      otto.security.configure(
        csrf_protection: true,
        trusted_proxies: ['127.0.0.1']
      )

      # Security config should be updated
      expect(otto.security_config.csrf_enabled?).to be true
      expect(otto.security_config.trusted_proxy?('127.0.0.1')).to be true

      # Middleware should be in stack
      expect(otto.middleware.includes?(Otto::Security::CSRFMiddleware)).to be true
    end
  end

  describe 'edge cases' do
    it 'handles empty middleware stack gracefully' do
      # Mock handle_request
      allow(otto).to receive(:handle_request).and_return([200, {}, ['base']])

      result = otto.call({})
      expect(result).to eq([200, {}, ['base']])
    end

    it 'handles middleware with custom arguments' do
      otto.use(test_middleware1, 'arg1', option: 'value')

      # Check middleware details
      details = otto.middleware.middleware_details
      middleware_detail = details.find { |d| d[:middleware] == test_middleware1 }
      expect(middleware_detail[:args]).to eq(['arg1'])
      expect(middleware_detail[:options]).to eq(option: 'value')
    end
  end
end
