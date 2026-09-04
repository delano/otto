# spec/otto/mcp/server_middleware_order_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# MCP mounts three middlewares and the order they EXECUTE in is a security
# property: rate limiting must shed load before anything else spends work, and
# authentication must reject anonymous callers before the schema validator
# parses their bodies.
#
# MiddlewareStack stores entries in the reverse of execution order, and the
# original MCP code read the position hints (:first / :last) as if they were
# execution order — producing the exact inverse: validation, then auth, then
# rate limiting. These examples pin the real order.
RSpec.describe Otto::MCP::Server do
  include_context 'with rack attack isolation'

  let(:token) { 'super-secret-token' }

  # Missing "id", and a bad jsonrpc version: rejected by the MCP request schema.
  let(:invalid_body) { JSON.generate({ jsonrpc: '1.0', method: 'tools/list' }) }

  def build_otto(**opts)
    otto = Otto.new(nil, { mcp_enabled: true, auth_tokens: [token] }.merge(opts))
    Otto.unfreeze_for_testing(otto)
    otto
  end

  # Rack::MockRequest.env_for leaves REMOTE_ADDR unset, and Rack::Attack's
  # throttle discriminators key on request.ip — without it every throttle
  # returns nil and silently never trips.
  def env_for(body, headers: {}, path: '/_mcp')
    env = Rack::MockRequest.env_for(path, method: 'POST', input: body,
                                          'CONTENT_TYPE' => 'application/json',
                                          'REMOTE_ADDR' => '203.0.113.9')
    headers.each { |k, v| env[k] = v }
    env
  end

  def post(app, body, headers: {}, path: '/_mcp')
    status, _headers, resp = app.call(env_for(body, headers: headers, path: path))
    [status, resp.to_a.join]
  end

  describe 'the assembled stack' do
    let(:otto) { build_otto }

    let(:mcp_execution_order) do
      mcp = [
        Otto::MCP::RateLimitMiddleware,
        Otto::MCP::Auth::TokenMiddleware,
        Otto::MCP::SchemaValidationMiddleware,
      ]
      otto.middleware.execution_order.select { |m| mcp.include?(m) }
    end

    it 'runs rate limiting, then auth, then validation' do
      expect(mcp_execution_order).to eq(
        [
          Otto::MCP::RateLimitMiddleware,
          Otto::MCP::Auth::TokenMiddleware,
          Otto::MCP::SchemaValidationMiddleware,
        ]
      )
    end

    it 'reports no ordering warnings' do
      expect(otto.middleware.validate_mcp_middleware_order).to be_empty
    end

    # TokenMiddleware only guards a request whose env carries the configured
    # endpoint, which the proc appended by add_mcp_endpoint_route sets. That
    # proc must stay OUTSIDE the auth middleware or auth silently passes
    # everything through.
    it 'sets otto.mcp_http_endpoint outside the auth middleware' do
      order         = otto.middleware.execution_order
      endpoint_proc = order.index { |m| m.is_a?(Proc) }
      auth          = order.index(Otto::MCP::Auth::TokenMiddleware)

      expect(endpoint_proc).not_to be_nil
      expect(endpoint_proc).to be < auth
    end

    it 'honors a custom endpoint through that proc' do
      custom = build_otto(mcp_endpoint: '/api/mcp')

      expect(post(custom, invalid_body, path: '/api/mcp').first).to eq(401)
    end
  end

  describe 'authentication runs before schema validation' do
    let(:otto) { build_otto }

    it 'answers 401, not a validation error, for an unauthenticated invalid request' do
      status, body = post(otto, invalid_body)

      expect(status).to eq(401)
      expect(JSON.parse(body).dig('error', 'message')).to eq('Unauthorized')
      expect(body).not_to include('Invalid MCP request')
    end

    it 'reaches the validator only once the token is valid' do
      skip 'json_schemer not available' unless defined?(JSONSchemer)

      status, body = post(otto, invalid_body,
                          headers: { 'HTTP_AUTHORIZATION' => "Bearer #{token}" })

      expect(status).to eq(400)
      expect(body).to include('Invalid MCP request')
    end

    it 'still serves a valid authenticated request' do
      valid = JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })
      status, body = post(otto, valid, headers: { 'HTTP_AUTHORIZATION' => "Bearer #{token}" })

      expect(status).to eq(200)
      expect(JSON.parse(body)['result']).to include('tools')
    end
  end

  describe 'rate limiting runs before authentication' do
    # Otto's RateLimitMiddleware is a CONFIGURATOR: it registers the throttles
    # and passes through, while Rack::Attack itself is mounted by the hosting
    # app ahead of Otto (see Otto::Security::RateLimitMiddleware). So the
    # deployed shape is Rack::Attack wrapping Otto, and that is what this
    # exercises: once the limit trips, the throttled response wins over the 401
    # the auth middleware would otherwise return.
    before do
      skip 'rack-attack not available' unless defined?(Rack::Attack)
      # rack-attack ships no default store outside Rails, so nothing would count.
      Rack::Attack.cache.store = RackAttackTestStore.new
    end

    let(:otto) { build_otto(requests_per_minute: 1) }
    let(:app) { Rack::Attack.new(otto) }

    it 'answers 429 before auth is consulted' do
      expect(post(app, invalid_body).first).to eq(401)

      status, body = post(app, invalid_body)

      expect(status).to eq(429)
      expect(JSON.parse(body).dig('error', 'message')).to eq('Rate limit exceeded')
    end

    it 'throttles a request that carries a valid token just the same' do
      headers = { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
      valid   = JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })

      expect(post(app, valid, headers: headers).first).to eq(200)
      expect(post(app, valid, headers: headers).first).to eq(429)
    end
  end

  describe 'rate limiting on a custom endpoint' do
    # Same deployed shape as above, but the endpoint is not the default. The
    # throttles used to read env['otto.mcp_http_endpoint'], which is set by a
    # proc INSIDE Otto's stack — and Rack::Attack runs before any of it. They
    # fell back to '/_mcp', so a custom endpoint was never throttled. The
    # endpoint now travels with the rate limiting config.
    before do
      skip 'rack-attack not available' unless defined?(Rack::Attack)
      Rack::Attack.cache.store = RackAttackTestStore.new
    end

    let(:endpoint) { '/api/mcp' }
    let(:headers) { { 'HTTP_AUTHORIZATION' => "Bearer #{token}" } }
    let(:tools_list) { JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }) }
    let(:tools_call) do
      JSON.generate({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'missing', arguments: {} } })
    end

    it 'publishes the endpoint alongside the limits' do
      otto = build_otto(mcp_endpoint: endpoint)

      expect(otto.security_config.rate_limiting_config).to include(mcp_http_endpoint: endpoint)
    end

    it 'throttles the custom endpoint through Rack::Attack mounted outside Otto' do
      app = Rack::Attack.new(build_otto(mcp_endpoint: endpoint, requests_per_minute: 1))

      expect(post(app, tools_list, headers: headers, path: endpoint).first).to eq(200)

      status, body = post(app, tools_list, headers: headers, path: endpoint)

      expect(status).to eq(429)
      expect(JSON.parse(body)).to include('jsonrpc' => '2.0')
      expect(JSON.parse(body).dig('error', 'message')).to eq('Rate limit exceeded')
    end

    it 'throttles tools/call on the custom endpoint' do
      app = Rack::Attack.new(build_otto(mcp_endpoint: endpoint, tools_per_minute: 1))

      # tools/list does not count against the tool-call limit. The tool itself
      # is unknown, so the protocol rejects the first call — what matters is
      # that the throttle still counted it.
      expect(post(app, tools_list, headers: headers, path: endpoint).first).to eq(200)
      expect(post(app, tools_call, headers: headers, path: endpoint).first).not_to eq(429)
      expect(post(app, tools_call, headers: headers, path: endpoint).first).to eq(429)
    end

    it 'leaves other paths on the general limiter' do
      app = Rack::Attack.new(build_otto(mcp_endpoint: endpoint, requests_per_minute: 1))

      post(app, tools_list, headers: headers, path: endpoint)
      expect(post(app, tools_list, headers: headers, path: endpoint).first).to eq(429)
      expect(post(app, tools_list, headers: headers, path: '/_mcp').first).not_to eq(429)
    end
  end
end
