# spec/otto/mcp/rate_limiting_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP, 'rate limiting features' do
  # These examples rewrite the process-global Rack::Attack configuration.
  include_context 'with rack attack isolation'

  before do
    Otto::Security::RateLimiting.ensure_available!
  rescue Otto::OptionalDependencyError => e
    skip e.message
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

    # Rack::Attack runs OUTSIDE Otto, ahead of the proc that sets
    # env['otto.mcp_http_endpoint'], so the throttles cannot learn a custom
    # endpoint from the env. It has to come in with the configuration.
    describe 'endpoint resolution' do
      let(:match_data) { { limit: 1, period: 60, epoch_time: Time.now.to_i } }

      def bare_request(path, env = {})
        Rack::Attack::Request.new(
          Rack::MockRequest.env_for(path, method: 'POST', 'REMOTE_ADDR' => '203.0.113.9').merge(env)
        )
      end

      it 'throttles the configured endpoint with no env key present' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/api/mcp')

        throttle = Rack::Attack.throttles['mcp_requests:/api/mcp']

        expect(throttle.block.call(bare_request('/api/mcp'))).to eq('203.0.113.9')
        expect(throttle.block.call(bare_request('/_mcp'))).to be_nil
      end

      it 'prefers the configured endpoint over the env key' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/api/mcp')

        throttle = Rack::Attack.throttles['mcp_requests:/api/mcp']
        request  = bare_request('/_mcp', 'otto.mcp_http_endpoint' => '/_mcp')

        expect(throttle.block.call(request)).to be_nil
      end

      it 'falls back to the env key, then to /_mcp, when none is configured' do
        Otto::MCP::RateLimiter.configure_rack_attack!({})

        throttle = Rack::Attack.throttles['mcp_requests']

        expect(throttle.block.call(bare_request('/api/mcp', 'otto.mcp_http_endpoint' => '/api/mcp')))
          .to eq('203.0.113.9')
        expect(throttle.block.call(bare_request('/_mcp'))).to eq('203.0.113.9')
        expect(throttle.block.call(bare_request('/api/mcp'))).to be_nil
      end

      it 'answers JSON-RPC on the configured endpoint with no env key present' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/api/mcp')

        request = bare_request('/api/mcp', 'rack.attack.match_data' => match_data)
        status, headers, body = Rack::Attack.throttled_responder.call(request)

        expect(status).to eq(429)
        expect(headers['content-type']).to eq('application/json')
        expect(JSON.parse(body.join)).to include('jsonrpc' => '2.0')
      end
    end

    # Rack::Attack keys throttles by name, process-wide. Registering
    # 'mcp_requests' for a second MCP app used to replace the first app's
    # throttle, and with it the captured endpoint: /a went unthrottled the
    # moment /b was configured.
    describe 'multiple MCP apps in one process' do
      let(:token) { 'multi-app-token' }
      let(:match_data) { { limit: 1, period: 60, epoch_time: Time.now.to_i } }

      def mcp_env(path, ip: '203.0.113.9')
        Rack::MockRequest.env_for(
          path,
          method: 'POST',
          input: JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }),
          'CONTENT_TYPE' => 'application/json',
          'HTTP_AUTHORIZATION' => "Bearer #{token}",
          'REMOTE_ADDR' => ip
        )
      end

      def mcp_app(endpoint, **opts)
        otto = Otto.new(nil, { mcp_enabled: true, mcp_endpoint: endpoint, auth_tokens: [token] }.merge(opts))
        Otto.unfreeze_for_testing(otto)
        otto
      end

      it 'registers every configured endpoint' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/a')
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/b')

        expect(Otto::MCP::RateLimiter.registered_endpoints).to eq(['/a', '/b'])
      end

      it 'keeps one throttle pair per endpoint, each with its own limit' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/a', mcp_requests_per_minute: 1)
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/b', mcp_requests_per_minute: 7)

        expect(Rack::Attack.throttles.keys).to include(
          'mcp_requests:/a', 'mcp_tool_calls:/a', 'mcp_requests:/b', 'mcp_tool_calls:/b'
        )
        expect(Rack::Attack.throttles['mcp_requests:/a'].limit).to eq(1)
        expect(Rack::Attack.throttles['mcp_requests:/b'].limit).to eq(7)
      end

      it 'answers JSON-RPC on the first endpoint after a second one is configured' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/a')
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/b')

        request = Rack::Attack::Request.new(
          Rack::MockRequest.env_for('/a', method: 'POST').merge('rack.attack.match_data' => match_data)
        )
        status, headers, body = Rack::Attack.throttled_responder.call(request)

        expect(status).to eq(429)
        expect(headers['content-type']).to eq('application/json')
        expect(JSON.parse(body.join)).to include('jsonrpc' => '2.0')
      end

      it 'still throttles the first app after a second app is constructed' do
        Rack::Attack.cache.store = RackAttackTestStore.new

        app_a = mcp_app('/a', requests_per_minute: 1)
        app_b = mcp_app('/b', requests_per_minute: 1)
        stack = Rack::Attack.new(->(env) { env['PATH_INFO'].start_with?('/a') ? app_a.call(env) : app_b.call(env) })

        statuses = ['/a', '/b', '/a', '/b'].map { |path| stack.call(mcp_env(path)).first }

        expect(statuses).to eq([200, 200, 429, 429])
      end

      it 'counts each endpoint independently' do
        Rack::Attack.cache.store = RackAttackTestStore.new

        app_a = mcp_app('/a', requests_per_minute: 1)
        app_b = mcp_app('/b', requests_per_minute: 2)
        stack = Rack::Attack.new(->(env) { env['PATH_INFO'].start_with?('/a') ? app_a.call(env) : app_b.call(env) })

        expect(stack.call(mcp_env('/a')).first).to eq(200)
        expect(stack.call(mcp_env('/b')).first).to eq(200)
        expect(stack.call(mcp_env('/b')).first).to eq(200)
        expect(stack.call(mcp_env('/b')).first).to eq(429)
      end
    end

    describe '.mcp_request?' do
      def bare_request(path, env = {})
        Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: 'POST').merge(env))
      end

      it 'matches any registered endpoint' do
        Otto::MCP::RateLimiter.register_endpoint('/a')
        Otto::MCP::RateLimiter.register_endpoint('/b')

        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/a'))).to be true
        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/b'))).to be true
        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/_mcp'))).to be false
      end

      it 'falls back to the env key, then to /_mcp, when nothing is registered' do
        Otto::MCP::RateLimiter.reset_endpoints!

        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/x', 'otto.mcp_http_endpoint' => '/x'))).to be true
        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/_mcp'))).to be true
        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/x'))).to be false
      end
    end

    # The router dispatches the MCP route by exact (normalized) literal match,
    # but the throttles and the responder classified by prefix. With MCP on
    # /a, ordinary /admin traffic was counted against 'mcp_requests:/a' and,
    # once that counter was exhausted, answered with an MCP JSON-RPC 429 even
    # though /admin can never reach the MCP handler. With MCP on / that was
    # every route in the app.
    describe 'exact endpoint matching' do
      let(:match_data) { { limit: 1, period: 60, epoch_time: Time.now.to_i } }

      def bare_request(path, env = {})
        Rack::Attack::Request.new(
          Rack::MockRequest.env_for(path, method: 'POST', 'REMOTE_ADDR' => '203.0.113.9').merge(env)
        )
      end

      def tools_call_request(path)
        bare_request(path, 'rack.input' => StringIO.new(JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/call' })))
      end

      it 'does not count a sibling path against the endpoint throttle' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/a')
        throttle = Rack::Attack.throttles['mcp_requests:/a']

        expect(throttle.block.call(bare_request('/a'))).to eq('203.0.113.9')
        expect(throttle.block.call(bare_request('/admin'))).to be_nil
        expect(throttle.block.call(bare_request('/a/b'))).to be_nil
        expect(throttle.block.call(bare_request('/ab'))).to be_nil
      end

      it 'does not count a sibling path against the tool-call throttle' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/a')
        throttle = Rack::Attack.throttles['mcp_tool_calls:/a']

        expect(throttle.block.call(tools_call_request('/a'))).to eq('203.0.113.9')
        expect(throttle.block.call(tools_call_request('/admin'))).to be_nil
      end

      it 'does not claim every route when the endpoint is the root' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/')
        throttle = Rack::Attack.throttles['mcp_requests:/']

        expect(throttle.block.call(bare_request('/'))).to eq('203.0.113.9')
        expect(throttle.block.call(bare_request('/anything'))).to be_nil
        expect(throttle.block.call(bare_request('/_mcp'))).to be_nil
      end

      # The router strips one trailing slash before its literal lookup, so
      # /a/ dispatches to an endpoint at /a and must be throttled like it.
      it 'normalizes a trailing slash the way the router does' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/a')
        throttle = Rack::Attack.throttles['mcp_requests:/a']

        expect(throttle.block.call(bare_request('/a/'))).to eq('203.0.113.9')
      end

      it 'classifies only the exact endpoint as an MCP request' do
        Otto::MCP::RateLimiter.register_endpoint('/a')

        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/a'))).to be true
        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/a/'))).to be true
        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/admin'))).to be false
        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/a/b'))).to be false
      end

      it 'classifies nothing but the root as MCP when the endpoint is the root' do
        Otto::MCP::RateLimiter.register_endpoint('/')

        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/'))).to be true
        expect(Otto::MCP::RateLimiter.mcp_request?(bare_request('/anything'))).to be false
      end

      it 'answers a sibling path with the general 429, not the JSON-RPC one' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/a')

        request = bare_request('/admin', 'rack.attack.match_data' => match_data)
        status, _headers, body = Rack::Attack.throttled_responder.call(request)

        # No route definition and no Accept header: the general responder
        # answers text/plain, never a JSON-RPC envelope.
        expect(status).to eq(429)
        expect(body.join).to include('Rate limit exceeded')
        expect(body.join).not_to include('jsonrpc')
      end

      it 'still answers the endpoint itself with the JSON-RPC 429' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/a')

        request = bare_request('/a', 'rack.attack.match_data' => match_data)
        status, _headers, body = Rack::Attack.throttled_responder.call(request)

        expect(status).to eq(429)
        expect(JSON.parse(body.join)).to include('jsonrpc' => '2.0')
      end
    end

    # The router dispatches on PATH_INFO alone. Under `map '/api' { run otto }`
    # the MCP request arrives as SCRIPT_NAME=/api, PATH_INFO=/_mcp, and
    # Rack::Request#path (SCRIPT_NAME + PATH_INFO) reads /api/_mcp: comparing
    # #path against the endpoint meant a mounted Otto was never throttled.
    describe 'mounted under a prefix' do
      let(:match_data) { { limit: 1, period: 60, epoch_time: Time.now.to_i } }

      def mounted_request(script_name, path_info, env = {})
        Rack::Attack::Request.new(
          Rack::MockRequest.env_for(path_info, method: 'POST', 'REMOTE_ADDR' => '203.0.113.9',
                                               script_name: script_name).merge(env)
        )
      end

      def tools_call_body
        StringIO.new(JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/call' }))
      end

      it 'throttles the endpoint by PATH_INFO, ignoring SCRIPT_NAME' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/_mcp')
        throttle = Rack::Attack.throttles['mcp_requests:/_mcp']

        request = mounted_request('/api', '/_mcp')
        expect(request.path).to eq('/api/_mcp')
        expect(throttle.block.call(request)).to eq('203.0.113.9')
      end

      it 'throttles tool calls by PATH_INFO, ignoring SCRIPT_NAME' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/_mcp')
        throttle = Rack::Attack.throttles['mcp_tool_calls:/_mcp']

        request = mounted_request('/api', '/_mcp', 'rack.input' => tools_call_body)
        expect(throttle.block.call(request)).to eq('203.0.113.9')
      end

      # The router would not dispatch this: PATH_INFO is / and the endpoint is
      # /_mcp. The full path happening to spell the endpoint must not count.
      it 'does not count a request whose full path equals the endpoint but PATH_INFO does not' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/_mcp')
        throttle = Rack::Attack.throttles['mcp_requests:/_mcp']

        request = mounted_request('/_mcp', '/')
        expect(request.path).to eq('/_mcp/')
        expect(throttle.block.call(request)).to be_nil
      end

      it 'classifies a mounted endpoint request as MCP' do
        Otto::MCP::RateLimiter.register_endpoint('/_mcp')

        expect(Otto::MCP::RateLimiter.mcp_request?(mounted_request('/api', '/_mcp'))).to be true
        expect(Otto::MCP::RateLimiter.mcp_request?(mounted_request('/_mcp', '/'))).to be false
      end

      it 'answers a mounted endpoint request with the JSON-RPC 429' do
        Otto::MCP::RateLimiter.configure_rack_attack!(mcp_http_endpoint: '/_mcp')

        request = mounted_request('/api', '/_mcp', 'rack.attack.match_data' => match_data)
        status, headers, body = Rack::Attack.throttled_responder.call(request)

        expect(status).to eq(429)
        expect(headers['content-type']).to eq('application/json')
        expect(JSON.parse(body.join)).to include('jsonrpc' => '2.0')
      end

      it 'throttles an Otto mounted with Rack::Builder#map when Rack::Attack shares the mount' do
        Rack::Attack.cache.store = RackAttackTestStore.new

        token = 'mounted-token'
        otto  = Otto.new(nil, mcp_enabled: true, mcp_endpoint: '/_mcp', auth_tokens: [token], requests_per_minute: 1)
        Otto.unfreeze_for_testing(otto)

        # Rack::Attack goes inside the map so it sees the same SCRIPT_NAME /
        # PATH_INFO split as Otto does (see docs/guides/mcp.md).
        stack = Rack::Builder.new do
          map('/api') do
            use Rack::Attack
            run otto
          end
        end.to_app

        env = lambda do
          Rack::MockRequest.env_for(
            '/api/_mcp',
            method: 'POST',
            input: JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }),
            'CONTENT_TYPE' => 'application/json',
            'HTTP_AUTHORIZATION' => "Bearer #{token}",
            'REMOTE_ADDR' => '203.0.113.9'
          )
        end

        first  = stack.call(env.call)
        second = stack.call(env.call)

        expect(first.first).to eq(200)
        expect(second.first).to eq(429)
        expect(JSON.parse(second.last.join)).to include('jsonrpc' => '2.0')
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

    it 'raises a clear error when rack-attack is not available' do
      error = Otto::OptionalDependencyError.new('Rate limiting requires rack-attack ~> 6.7')
      allow(Otto::Security::RateLimiting).to receive(:ensure_available!).and_raise(error)

      expect { Otto::MCP::RateLimitMiddleware.new(app, security_config) }
        .to raise_error(Otto::OptionalDependencyError, /rack-attack.*~> 6\.7/)
    end
  end

  describe 'MCP Server integration' do
    let(:otto) { create_minimal_otto }

    it 'passes security config to MCP rate limiting middleware' do
      # Enable MCP with rate limiting
      otto.enable_mcp!(enable_rate_limiting: true)

      # Check that the middleware was added with security config
      expect(otto.middleware_stack).to include(Otto::MCP::RateLimitMiddleware)
    end

    it 'configures MCP endpoint in environment for rate limiting' do
      custom_endpoint = '/api/mcp'
      otto.enable_mcp!(http_endpoint: custom_endpoint, enable_rate_limiting: true)

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
        path_info: '/_mcp'
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('application/json')

      response = JSON.parse(body.join)
      expect(response['jsonrpc']).to eq('2.0')
      expect(response['error']['code']).to eq(-32_000)
    end
  end

  describe 'non-MCP throttled_responder route response_type precedence' do
    # These tests verify that when a non-MCP route declares response=json,
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

      # Configure MCP rate limiting (which overrides throttled_response)
      Otto::MCP::RateLimiter.configure_rack_attack!({})
    end

    let(:match_data) do
      { limit: 100, period: 60, epoch_time: Time.now.to_i }
    end

    it 'returns JSON when non-MCP route declares response=json regardless of Accept header' do
      json_route = Otto::RouteDefinition.new('POST', '/api/data', 'ApiLogic response=json')

      request = instance_double(
        'Rack::Request',
        env: {
          'HTTP_ACCEPT' => 'text/html',
          'rack.attack.match_data' => match_data,
          'otto.route_definition' => json_route,
          'otto.mcp_http_endpoint' => '/_mcp',
        },
        path_info: '/api/data'  # Non-MCP path
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('application/json')
      response_body = JSON.parse(body.first)
      expect(response_body['error']).to eq('Rate limit exceeded')
      # Should NOT be JSON-RPC format (that's for MCP only)
      expect(response_body).not_to have_key('jsonrpc')
    end

    it 'returns JSON when non-MCP route declares response=json with no Accept header' do
      json_route = Otto::RouteDefinition.new('POST', '/api/data', 'ApiLogic response=json')

      request = instance_double(
        'Rack::Request',
        env: {
          'rack.attack.match_data' => match_data,
          'otto.route_definition' => json_route,
          'otto.mcp_http_endpoint' => '/_mcp',
        },
        path_info: '/api/data'  # Non-MCP path
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('application/json')
      response_body = JSON.parse(body.first)
      expect(response_body['error']).to eq('Rate limit exceeded')
    end

    it 'falls back to Accept header when non-MCP route has no response_type' do
      default_route = Otto::RouteDefinition.new('GET', '/page', 'PageLogic')

      request = instance_double(
        'Rack::Request',
        env: {
          'HTTP_ACCEPT' => 'application/json',
          'rack.attack.match_data' => match_data,
          'otto.route_definition' => default_route,
          'otto.mcp_http_endpoint' => '/_mcp',
        },
        path_info: '/page'  # Non-MCP path
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('application/json')
      response_body = JSON.parse(body.first)
      expect(response_body['error']).to eq('Rate limit exceeded')
    end

    it 'returns text/plain when non-MCP route has no response_type and Accept is text/html' do
      default_route = Otto::RouteDefinition.new('GET', '/page', 'PageLogic')

      request = instance_double(
        'Rack::Request',
        env: {
          'HTTP_ACCEPT' => 'text/html',
          'rack.attack.match_data' => match_data,
          'otto.route_definition' => default_route,
          'otto.mcp_http_endpoint' => '/_mcp',
        },
        path_info: '/page'  # Non-MCP path
      )

      status, headers, body = Rack::Attack.throttled_responder.call(request)

      expect(status).to eq(429)
      expect(headers['content-type']).to eq('text/plain')
      expect(body.first).to include('Rate limit exceeded')
    end
  end
end
