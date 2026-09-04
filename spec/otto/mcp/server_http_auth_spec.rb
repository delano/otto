# spec/otto/mcp/server_http_auth_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Integration coverage for issue #258: the Otto constructor used to drop every
# MCP option except the endpoint, so `Otto.new(nil, mcp_enabled: true,
# auth_tokens: [...])` silently served an unauthenticated MCP endpoint. These
# examples drive real requests through otto.call for BOTH the constructor path
# and the explicit #enable_mcp! path.
RSpec.describe Otto::MCP::Server do
  # Building an Otto with MCP rate limiting re-registers the process-global
  # Rack::Attack throttles; restore them so other specs see their own limits.
  include_context 'with rack attack isolation'

  # HTTP endpoint authentication, end to end.
  let(:token) { 'super-secret-token' }

  def mcp_request(otto, endpoint: '/_mcp', method_name: 'tools/list', headers: {}, id: 1)
    body = JSON.generate({ jsonrpc: '2.0', id: id, method: method_name, params: {} })
    env  = Rack::MockRequest.env_for(
      endpoint,
      method: 'POST',
      input: body,
      'CONTENT_TYPE' => 'application/json'
    )
    headers.each { |k, v| env[k] = v }

    status, _resp_headers, resp_body = otto.call(env)
    [status, JSON.parse(resp_body.to_a.join)]
  end

  def constructor_otto(**opts)
    otto = Otto.new(nil, { mcp_enabled: true }.merge(opts))
    Otto.unfreeze_for_testing(otto)
    otto
  end

  def explicit_otto(**opts)
    otto = create_minimal_otto
    otto.enable_mcp!(**opts)
    otto
  end

  {
    'constructor path (Otto.new(mcp_enabled: true))' => :constructor_otto,
    'explicit path (#enable_mcp!)' => :explicit_otto,
  }.each do |description, builder|
    describe description do
      let(:otto) { send(builder, auth_tokens: [token]) }

      it 'wires a TokenAuth into the security config' do
        expect(otto.security_config.mcp_auth).to be_a(Otto::MCP::Auth::TokenAuth)
      end

      it 'mounts the token middleware' do
        expect(otto.middleware_stack).to include(Otto::MCP::Auth::TokenMiddleware)
      end

      it 'rejects a request with no token' do
        status, body = mcp_request(otto)

        expect(status).to eq(401)
        expect(body.dig('error', 'message')).to eq('Unauthorized')
      end

      it 'rejects an invalid bearer token' do
        status, body = mcp_request(otto, headers: { 'HTTP_AUTHORIZATION' => 'Bearer wrong-token' })

        expect(status).to eq(401)
        expect(body.dig('error', 'code')).to eq(-32_000)
      end

      it 'rejects a malformed Authorization header' do
        status, = mcp_request(otto, headers: { 'HTTP_AUTHORIZATION' => token })

        expect(status).to eq(401)
      end

      it 'accepts a valid bearer token and answers tools/list' do
        status, body = mcp_request(otto, headers: { 'HTTP_AUTHORIZATION' => "Bearer #{token}" })

        expect(status).to eq(200)
        expect(body).to include('jsonrpc' => '2.0', 'id' => 1)
        expect(body['result']).to include('tools')
        expect(body).not_to have_key('error')
      end

      it 'accepts a valid X-MCP-Token header and answers initialize' do
        status, body = mcp_request(
          otto,
          method_name: 'initialize',
          id: 7,
          headers: { 'HTTP_X_MCP_TOKEN' => token }
        )

        expect(status).to eq(200)
        expect(body['id']).to eq(7)
        expect(body.dig('result', 'serverInfo', 'name')).to eq('Otto MCP Server')
      end

      it 'rejects an invalid X-MCP-Token header' do
        status, = mcp_request(otto, headers: { 'HTTP_X_MCP_TOKEN' => 'nope' })

        expect(status).to eq(401)
      end
    end
  end

  describe 'path equivalence between the two entry points' do
    let(:from_constructor) { constructor_otto(auth_tokens: [token]) }
    let(:from_explicit) { explicit_otto(auth_tokens: [token]) }

    it 'builds the same middleware stack' do
      classes = ->(otto) { otto.middleware_stack.grep(Class) }

      expect(classes.call(from_constructor)).to eq(classes.call(from_explicit))
    end

    it 'configures the same endpoint' do
      endpoint = ->(otto) { otto.mcp_server.instance_variable_get(:@http_endpoint) }

      expect(endpoint.call(from_constructor)).to eq(endpoint.call(from_explicit))
    end

    it 'answers identically to the same authenticated request' do
      headers = { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }

      expect(mcp_request(from_constructor, headers: headers))
        .to eq(mcp_request(from_explicit, headers: headers))
    end
  end

  describe 'custom endpoint' do
    it 'honors mcp_endpoint: from the constructor and still requires auth' do
      otto = constructor_otto(mcp_endpoint: '/api/mcp', auth_tokens: [token])

      expect(mcp_request(otto, endpoint: '/api/mcp').first).to eq(401)
      expect(mcp_request(otto, endpoint: '/api/mcp',
                               headers: { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }).first).to eq(200)
    end

    it 'honors endpoint: from #enable_mcp! and still requires auth' do
      otto = explicit_otto(endpoint: '/api/mcp', auth_tokens: [token])

      expect(mcp_request(otto, endpoint: '/api/mcp').first).to eq(401)
      expect(mcp_request(otto, endpoint: '/api/mcp',
                               headers: { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }).first).to eq(200)
    end
  end

  describe 'without configured tokens' do
    let(:otto) { constructor_otto(allow_unauthenticated: true) }

    it 'leaves mcp_auth unset' do
      expect(otto.security_config.mcp_auth).to be_nil
    end

    it 'does not mount the token middleware' do
      expect(otto.middleware_stack).not_to include(Otto::MCP::Auth::TokenMiddleware)
    end

    it 'serves the endpoint to anyone' do
      status, body = mcp_request(otto)

      expect(status).to eq(200)
      expect(body['result']).to include('tools')
    end
  end

  describe 'rate limit passthrough' do
    it 'publishes constructor limits to the security config' do
      otto = constructor_otto(auth_tokens: [token], requests_per_minute: 5, tools_per_minute: 2)

      expect(otto.security_config.rate_limiting_config)
        .to include(mcp_requests_per_minute: 5, tool_calls_per_minute: 2)
    end

    it 'publishes #enable_mcp! limits to the security config' do
      otto = explicit_otto(auth_tokens: [token], requests_per_minute: 5, tools_per_minute: 2)

      expect(otto.security_config.rate_limiting_config)
        .to include(mcp_requests_per_minute: 5, tool_calls_per_minute: 2)
    end

    it 'accepts the mcp_-prefixed spellings' do
      otto = constructor_otto(mcp_requests_per_minute: 11, tool_calls_per_minute: 3)

      expect(otto.security_config.rate_limiting_config)
        .to include(mcp_requests_per_minute: 11, tool_calls_per_minute: 3)
    end

    it 'falls back to the documented defaults' do
      otto = constructor_otto(auth_tokens: [token])

      expect(otto.security_config.rate_limiting_config)
        .to include(mcp_requests_per_minute: 60, tool_calls_per_minute: 20)
    end

    it 'does not touch rate limiting config when disabled' do
      otto = constructor_otto(auth_tokens: [token], mcp_rate_limiting: false, requests_per_minute: 5)

      expect(otto.security_config.rate_limiting_config).not_to include(mcp_requests_per_minute: 5)
      expect(otto.middleware_stack).not_to include(Otto::MCP::RateLimitMiddleware)
    end
  end

  describe 'unauthenticated warning' do
    let(:default_warning) { format(Otto::MCP::Server::UNAUTHENTICATED_WARNING, '/_mcp') }

    before { allow(Otto.logger).to receive(:warn) }

    it 'warns once when no tokens are configured' do
      constructor_otto

      expect(Otto.logger).to have_received(:warn).with(default_warning).once
    end

    it 'names the configured endpoint' do
      constructor_otto(mcp_endpoint: '/api/mcp')

      expect(Otto.logger).to have_received(:warn)
        .with(format(Otto::MCP::Server::UNAUTHENTICATED_WARNING, '/api/mcp')).once
    end

    it 'warns on the explicit path too' do
      explicit_otto

      expect(Otto.logger).to have_received(:warn).with(default_warning).once
    end

    it 'stays silent when auth tokens are configured' do
      constructor_otto(auth_tokens: [token])

      expect(Otto.logger).not_to have_received(:warn).with(default_warning)
    end

    it 'stays silent when the exposure is acknowledged' do
      constructor_otto(allow_unauthenticated: true)

      expect(Otto.logger).not_to have_received(:warn).with(default_warning)
    end

    it 'explains both remedies' do
      expect(default_warning).to include(
        '/_mcp',
        'without authentication',
        "auth_tokens: ['<token>']",
        'allow_unauthenticated: true'
      )
    end
  end
end
