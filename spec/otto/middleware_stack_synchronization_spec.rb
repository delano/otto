# spec/otto/middleware_stack_synchronization_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Middleware Stack Synchronization' do
  let(:otto) { Otto.new }
  let(:test_middleware1) do
    Class.new do
      def initialize(app, *args)
        @app = app
      end
      def call(env)
        @app.call(env)
      end
    end
  end
  let(:test_middleware2) do
    Class.new do
      def initialize(app, *args)
        @app = app
      end
      def call(env)
        @app.call(env)
      end
    end
  end

  describe 'middleware synchronization' do
    it 'adds middleware to middleware stack via use method' do
      otto.use(test_middleware1)

      # Should be in middleware stack
      expect(otto.middleware.middleware_list).to include(test_middleware1)
    end

    it 'maintains order of middleware stack' do
      otto.use(test_middleware1)
      otto.use(test_middleware2)

      # Stack order (IP Privacy middleware is always first)
      expect(otto.middleware.middleware_list).to eq([Otto::Security::Middleware::IPPrivacyMiddleware, test_middleware1, test_middleware2])
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
    it 'builds middleware app at initialization' do
      # App should be built during initialization
      expect(otto.instance_variable_get(:@app)).not_to be_nil
      expect(otto.instance_variable_get(:@app)).to respond_to(:call)
    end

    it 'rebuilds app when middleware is added' do
      # Before adding middleware, count is 1 (IPPrivacyMiddleware is always present)
      expect(otto.middleware.size).to eq(1)

      otto.use(TestExecutionMiddleware)

      # After adding middleware, count is 2 and app should be TestExecutionMiddleware instance
      expect(otto.middleware.size).to eq(2)
      app = otto.instance_variable_get(:@app)
      expect(app).to be_a(TestExecutionMiddleware)
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
    it 'builds app even with empty middleware stack' do
      # Even with no middleware, app should be built
      app = otto.instance_variable_get(:@app)
      expect(app).not_to be_nil
      expect(app).to respond_to(:call)
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
