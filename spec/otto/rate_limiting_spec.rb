# spec/otto/rate_limiting_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'rate limiting features' do
  subject(:otto) { create_minimal_otto }

  before do
    Otto::Security::RateLimiting.ensure_available!
  rescue Otto::OptionalDependencyError => e
    skip e.message
  end

  describe '#enable_rate_limiting!' do
    it 'enables rate limiting with default settings' do
      otto.enable_rate_limiting!

      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be true
      expect(otto.security_config.rate_limiting_config).to be_a(Hash)
    end

    it 'fails before changing configuration when rack-attack is unavailable' do
      error = Otto::OptionalDependencyError.new('Rate limiting requires rack-attack ~> 6.7')
      allow(Otto::Security::RateLimiting).to receive(:ensure_available!).and_raise(error)

      expect { otto.enable_rate_limiting!(requests_per_minute: 50) }
        .to raise_error(Otto::OptionalDependencyError, /rack-attack.*~> 6\.7/)
      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be false
      expect(otto.security_config.rate_limiting_config[:requests_per_minute]).not_to eq(50)
    end

    it 'accepts custom rate limiting options' do
      otto.enable_rate_limiting!(requests_per_minute: 50)

      expect(otto.security_config.rate_limiting_config[:requests_per_minute]).to eq(50)
    end

    it 'does not add middleware twice when called multiple times' do
      otto.enable_rate_limiting!
      otto.enable_rate_limiting! # repeated intentionally for this testcase

      middleware_count = otto.middleware.middleware_list.count(Otto::Security::RateLimitMiddleware)
      expect(middleware_count).to eq(1)
    end
  end

  describe '#configure_rate_limiting' do
    it 'configures rate limiting settings' do
      config = {
        requests_per_minute: 75,
        custom_rules: {
          'api_calls' => { limit: 30, period: 60 },
        },
      }

      otto.configure_rate_limiting(config)

      expect(otto.security_config.rate_limiting_config[:requests_per_minute]).to eq(75)
      expect(otto.security_config.rate_limiting_config[:custom_rules]['api_calls'][:limit]).to eq(30)
    end

    it 'merges with existing configuration' do
      otto.configure_rate_limiting(requests_per_minute: 50)
      otto.configure_rate_limiting(custom_rules: { 'uploads' => { limit: 5 } })

      config = otto.security_config.rate_limiting_config
      expect(config[:requests_per_minute]).to eq(50)
      expect(config[:custom_rules]['uploads'][:limit]).to eq(5)
    end
  end

  describe '#add_rate_limit_rule' do
    it 'adds a custom rate limiting rule' do
      otto.add_rate_limit_rule('uploads', limit: 5, period: 300)

      rules = otto.security_config.rate_limiting_config[:custom_rules]
      expect(rules['uploads'][:limit]).to eq(5)
      expect(rules['uploads'][:period]).to eq(300)
    end

    it 'accepts symbol names and converts to string' do
      otto.add_rate_limit_rule(:api_heavy, limit: 10)

      rules = otto.security_config.rate_limiting_config[:custom_rules]
      expect(rules['api_heavy'][:limit]).to eq(10)
    end

    it 'supports condition procs' do
      condition = ->(req) { req.post? }
      otto.add_rate_limit_rule('posts', limit: 20, condition: condition)

      rules = otto.security_config.rate_limiting_config[:custom_rules]
      expect(rules['posts'][:condition]).to eq(condition)
    end
  end

  describe 'initialization with rate_limiting option' do
    it 'enables rate limiting when rate_limiting: true' do
      otto = Otto.new(nil, rate_limiting: true)

      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be true
    end

    it 'configures rate limiting when rate_limiting is a hash' do
      options = { requests_per_minute: 80 }
      otto = Otto.new(nil, rate_limiting: options)

      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be true
      expect(otto.security_config.rate_limiting_config[:requests_per_minute]).to eq(80)
    end

    it 'does not enable rate limiting when rate_limiting is false' do
      otto = Otto.new(nil, rate_limiting: false)

      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be false
    end
  end

  describe 'Otto::Security::RateLimiting' do
    describe '.configure_rack_attack!' do
      before do
        # Clear any existing Rack::Attack configuration
        if defined?(Rack::Attack)
          if Rack::Attack.respond_to?(:clear_configuration)
            Rack::Attack.clear_configuration
          else
            Rack::Attack.clear!
          end
        end
      end

      it 'configures basic rate limiting rules' do
        config = { requests_per_minute: 120 }
        Otto::Security::RateLimiting.configure_rack_attack!(config)

        # Check that throttles were configured
        expect(Rack::Attack.throttles).to have_key('requests')
      end

      it 'configures custom rules' do
        config = {
          custom_rules: {
            'heavy_api' => { limit: 10, period: 60 },
          },
        }
        Otto::Security::RateLimiting.configure_rack_attack!(config)

        expect(Rack::Attack.throttles).to have_key('heavy_api')
      end

      it 'raises a clear error when rack-attack is not available' do
        error = Otto::OptionalDependencyError.new('Rate limiting requires rack-attack ~> 6.7')
        allow(Otto::Security::RateLimiting).to receive(:ensure_available!).and_raise(error)

        expect { Otto::Security::RateLimiting.configure_rack_attack!({}) }
          .to raise_error(Otto::OptionalDependencyError, /rack-attack.*~> 6\.7/)
      end
    end
  end

  describe 'Otto::Security::RateLimitMiddleware' do
    let(:app) { ->(_env) { [200, {}, ['OK']] } }
    let(:security_config) { otto.security_config }
    let(:middleware) { Otto::Security::RateLimitMiddleware.new(app, security_config) }

    it 'initializes without errors when rack-attack is available' do
      expect { middleware }.not_to raise_error
    end

    it 'raises a clear error when rack-attack is not available' do
      error = Otto::OptionalDependencyError.new('Rate limiting requires rack-attack ~> 6.7')
      allow(Otto::Security::RateLimiting).to receive(:ensure_available!).and_raise(error)

      expect { Otto::Security::RateLimitMiddleware.new(app, security_config) }
        .to raise_error(Otto::OptionalDependencyError, /rack-attack.*~> 6\.7/)
    end

    it 'calls through to app when rate limiting is available' do
      env = Rack::MockRequest.env_for('/')
      status, _headers, body = middleware.call(env)

      expect(status).to eq(200)
      expect(body).to eq(['OK'])
    end
  end

  describe 'throttled_responder route response_type precedence' do
    # These tests verify that when a route declares response=json,
    # rate limit errors should return JSON regardless of the Accept header.
    # This mirrors the fix applied to Otto::Core::ErrorHandler.

    before do
      if defined?(Rack::Attack)
        if Rack::Attack.respond_to?(:clear_configuration)
          Rack::Attack.clear_configuration
        else
          Rack::Attack.clear!
        end
      end

      # Configure rate limiting to set up the throttled_responder
      Otto::Security::RateLimiting.configure_rack_attack!({})
    end

    let(:match_data) do
      { limit: 100, period: 60, epoch_time: Time.now.to_i }
    end

    it 'returns JSON when route declares response=json regardless of Accept header' do
      json_route = Otto::RouteDefinition.new('POST', '/api/data', 'ApiLogic response=json')

      request = instance_double(
        'Rack::Request',
        env: {
          'HTTP_ACCEPT' => 'text/html',
          'rack.attack.match_data' => match_data,
          'otto.route_definition' => json_route,
        },
        path: '/api/data'
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('application/json')
      response_body = JSON.parse(body.first)
      expect(response_body['error']).to eq('Rate limit exceeded')
    end

    it 'returns JSON when route declares response=json with no Accept header' do
      json_route = Otto::RouteDefinition.new('POST', '/api/data', 'ApiLogic response=json')

      request = instance_double(
        'Rack::Request',
        env: {
          'rack.attack.match_data' => match_data,
          'otto.route_definition' => json_route,
        },
        path: '/api/data'
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('application/json')
      response_body = JSON.parse(body.first)
      expect(response_body['error']).to eq('Rate limit exceeded')
    end

    it 'falls back to Accept header when route has no response_type' do
      default_route = Otto::RouteDefinition.new('GET', '/page', 'PageLogic')

      request = instance_double(
        'Rack::Request',
        env: {
          'HTTP_ACCEPT' => 'application/json',
          'rack.attack.match_data' => match_data,
          'otto.route_definition' => default_route,
        },
        path: '/page'
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('application/json')
      response_body = JSON.parse(body.first)
      expect(response_body['error']).to eq('Rate limit exceeded')
    end

    it 'returns text/plain when route has no response_type and Accept is text/html' do
      default_route = Otto::RouteDefinition.new('GET', '/page', 'PageLogic')

      request = instance_double(
        'Rack::Request',
        env: {
          'HTTP_ACCEPT' => 'text/html',
          'rack.attack.match_data' => match_data,
          'otto.route_definition' => default_route,
        },
        path: '/page'
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('text/plain')
      expect(body.first).to include('Rate limit exceeded')
    end
  end

  # Issue #219: the 'rack.attack' subscriber interpolated req.ip straight into a
  # warn-level line, so a deployment on the default :masked privacy profile
  # still wrote raw client IPs to its logs every time a limit tripped.
  #
  # ActiveSupport is not a dependency, so the subscriber is normally never
  # registered. Stand in a minimal Notifications double to capture the block and
  # drive it with a payload.
  describe 'blocked-request logging' do
    let(:notifications) do
      Class.new do
        attr_reader :subscriptions

        def initialize = (@subscriptions = {})
        def subscribe(name, &block) = (@subscriptions[name] = block)

        def publish(name, payload)
          @subscriptions.fetch(name).call(name, nil, nil, nil, payload)
        end
      end.new
    end

    let(:logged) { [] }

    def publish_throttle(env)
      request = instance_double('Rack::Request', env: env, ip: env['REMOTE_ADDR'], path: env['PATH_INFO'])
      notifications.publish('rack.attack', request: request, match_type: :throttle, matched: 'requests')
    end

    before do
      stub_const('ActiveSupport::Notifications', notifications)
      allow(Otto.logger).to receive(:warn) { |message| logged << message }
    end

    it 'logs a masked IP, never the raw client address' do
      Otto::Security::RateLimiting.configure_rack_attack!({})

      publish_throttle('REMOTE_ADDR' => '203.0.113.7', 'PATH_INFO' => '/api')

      expect(logged.last).to include('203.0.113.0')
      expect(logged.last).not_to include('203.0.113.7')
    end

    it 'prefers the canonical client IP when Rack::Attack runs inside Otto' do
      Otto::Security::RateLimiting.configure_rack_attack!({})

      publish_throttle(
        'REMOTE_ADDR' => '203.0.113.0',
        'PATH_INFO' => '/api',
        'otto.client_ip' => '203.0.113.0'
      )

      expect(logged.last).to include('203.0.113.0')
    end

    it 'masks the IP on the MCP subscriber too' do
      Otto::MCP::RateLimiter.configure_mcp_logging

      publish_throttle('REMOTE_ADDR' => '198.51.100.42', 'PATH_INFO' => '/_mcp')

      expect(logged.last).to start_with('[MCP]')
      expect(logged.last).to include('198.51.100.0')
      expect(logged.last).not_to include('198.51.100.42')
    end

    it 'masks the IP on the MCP subscriber for non-MCP paths' do
      Otto::MCP::RateLimiter.configure_mcp_logging

      publish_throttle('REMOTE_ADDR' => '198.51.100.42', 'PATH_INFO' => '/other')

      expect(logged.last).to start_with('[Otto]')
      expect(logged.last).not_to include('198.51.100.42')
    end
  end
end
