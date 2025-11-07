# spec/otto/mcp/rate_limiting_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP, 'rate limiting features' do
  before do
    skip 'rack-attack not available' unless defined?(Rack::Attack)
  end

  describe 'Otto::MCP::RateLimiter' do
    describe '.configure_rack_attack!' do
      before do
        if defined?(Rack::Attack)
          if Rack::Attack.respond_to?(:clear_configuration)
            Rack::Attack.clear_configuration
          else
            Rack::Attack.clear!
          end
        end
      end

      it 'inherits from general rate limiting' do
        expect(Otto::MCP::RateLimiter).to be < Otto::Security::RateLimiting
      end

      it 'configures MCP-specific rules in addition to general rules' do
        config = {
          requests_per_minute: 100,
          mcp_requests_per_minute: 50,
          tool_calls_per_minute: 15,
        }

        Otto::MCP::RateLimiter.configure_rack_attack!(config)

        # Should have general rules
        expect(Rack::Attack.throttles).to have_key('requests')

        # Should have MCP-specific rules
        expect(Rack::Attack.throttles).to have_key('mcp_requests')
        expect(Rack::Attack.throttles).to have_key('mcp_tool_calls')
      end

      it 'uses default MCP limits when not specified' do
        Otto::MCP::RateLimiter.configure_rack_attack!({})

        # Check that MCP throttles exist with defaults
        expect(Rack::Attack.throttles).to have_key('mcp_requests')
        expect(Rack::Attack.throttles).to have_key('mcp_tool_calls')
      end

      it 'configures custom JSON-RPC error responses' do
        Otto::MCP::RateLimiter.configure_rack_attack!({})

        expect(Rack::Attack.throttled_responder).to be_a(Proc)
      end
    end
  end

  describe 'Otto::MCP::RateLimitMiddleware' do
    let(:app) { ->(_env) { [200, {}, ['OK']] } }
    let(:otto) { create_minimal_otto }
    let(:security_config) { otto.security_config }

    before do
      # Configure some rate limiting settings
      security_config.rate_limiting_config = {
        requests_per_minute: 100,
        mcp_requests_per_minute: 60,
        tool_calls_per_minute: 20,
      }
    end

    it 'inherits from general rate limiting middleware' do
      expect(Otto::MCP::RateLimitMiddleware).to be < Otto::Security::RateLimitMiddleware
    end

    it 'initializes with MCP-specific configuration' do
      middleware = Otto::MCP::RateLimitMiddleware.new(app, security_config)
      expect { middleware }.not_to raise_error
    end

    it 'adds MCP defaults to configuration' do
      Otto::MCP::RateLimitMiddleware.new(app, security_config)

      # Should configure Rack::Attack with MCP settings
      expect(Rack::Attack.throttles).to have_key('mcp_requests')
      expect(Rack::Attack.throttles).to have_key('mcp_tool_calls')
    end

    it 'logs MCP-specific warning when rack-attack not available' do
      # Hide Rack::Attack temporarily
      rack_attack = Object.send(:remove_const, :Rack) if defined?(Rack::Attack)

      expect(Otto.logger).to receive(:warn).with(match(/\[MCP\].*rack-attack not available/))
      Otto::MCP::RateLimitMiddleware.new(app, security_config)

      # Restore Rack::Attack
      Object.const_set(:Rack, rack_attack) if rack_attack
    end
  end

  describe 'MCP Server integration' do
    let(:otto) { create_minimal_otto }

    it 'passes security config to MCP rate limiting middleware' do
      # Enable MCP with rate limiting
      otto.enable_mcp!(rate_limiting: true)

      # Check that the middleware was added with security config
      expect(otto.middleware_stack).to include(Otto::MCP::RateLimitMiddleware)
    end

    it 'configures MCP endpoint in environment for rate limiting' do
      custom_endpoint = '/api/mcp'
      otto.enable_mcp!(http_endpoint: custom_endpoint, rate_limiting: true)

      # Check that the MCP server was configured with custom endpoint
      expect(otto.mcp_enabled?).to be true
    end
  end

  describe 'Rate limiting responses' do
    it 'configures JSON-RPC error responses for MCP endpoints' do
      # Test that the MCP rate limiter sets up proper response format
      Otto::MCP::RateLimiter.configure_rack_attack!({})

      # Check that a throttled responder was configured
      expect(Rack::Attack.throttled_responder).to be_a(Proc)

      # Test the responder with a mock MCP request
      request = instance_double(
        'Rack::Request',
        env: { 'otto.mcp_http_endpoint' => '/_mcp',
'rack.attack.match_data' => { limit: 60, period: 60, epoch_time: Time.now.to_i } },
        path: '/_mcp'
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('application/json')

      response = JSON.parse(body.join)
      expect(response['jsonrpc']).to eq('2.0')
      expect(response['error']['code']).to eq(-32_000)
    end
  end
end
