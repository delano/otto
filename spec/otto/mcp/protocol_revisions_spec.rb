# spec/otto/mcp/protocol_revisions_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Which revision a request is served under, and what an endpoint that still
# serves 2024-11-05 gains from an authenticator and declared tools.
RSpec.describe Otto::MCP::Protocol do
  include_context 'with rack attack isolation'
  include_context 'with mcp 2026-07-28 requests'

  let(:options) { {} }
  let(:log)     { StringIO.new }
  let(:otto) do
    create_minimal_otto.tap do |app|
      app.enable_mcp!(http_endpoint: '/mcp', allow_unauthenticated: true, enable_rate_limiting: false, **options)
      app.mcp_server.protocol.registry.register_tool('echo', 'Echo', { type: 'object' }, 'TestMCPTool.echo')
    end
  end

  around do |example|
    previous    = Otto.logger
    Otto.logger = Logger.new(log)
    example.run
  ensure
    Otto.logger = previous
  end

  def legacy_call(method_name, params = {}, headers: {}, id: 1)
    env = Rack::MockRequest.env_for('/mcp', method: 'POST', 'CONTENT_TYPE' => 'application/json',
      input: JSON.generate({ jsonrpc: '2.0', id: id, method: method_name, params: params }))
    headers.each { |key, value| env[key] = value }
    status, response_headers, body = otto.call(env)
    [status, response_headers, JSON.parse(body.to_a.join)]
  end

  describe 'an endpoint enabled without protocol_versions' do
    it 'serves 2024-11-05, as it did before the option existed' do
      status, _headers, body = legacy_call('initialize')

      expect(status).to eq(200)
      expect(body['result']).to include('protocolVersion' => '2024-11-05')
      expect(body['result']).not_to have_key('resultType')
    end

    it 'serves a request in the 2026-07-28 shape as 2024-11-05 too' do
      status, _headers, body = modern_call(otto, 'tools/list')

      expect(status).to eq(200)
      expect(body['result']).to eq('tools' => [{ 'name' => 'echo', 'description' => 'Echo', 'inputSchema' => { 'type' => 'object' } }])
    end

    it 'does not know server/discover' do
      status, _headers, body = modern_call(otto, 'server/discover')

      expect(status).to eq(400)
      expect(body.dig('error', 'code')).to eq(-32_601)
    end

    it 'has no route for GET, checks no Origin and publishes no metadata document' do
      expect(otto.call(Rack::MockRequest.env_for('/mcp', method: 'GET')).first).to eq(404)
      expect(legacy_call('tools/list', {}, headers: { 'HTTP_ORIGIN' => 'https://anywhere.example' })[0]).to eq(200)
      expect(otto.middleware_stack).not_to include(Otto::MCP::OriginGuard)
      expect(otto.mcp_server.protected_resource_metadata).to be_nil
    end

    context 'with allowed_origins' do
      let(:options) { { allowed_origins: ['https://app.example.com'] } }

      it 'checks Origin' do
        expect(legacy_call('tools/list', {}, headers: { 'HTTP_ORIGIN' => 'https://app.example.com' })[0]).to eq(200)
        expect(legacy_call('tools/list', {}, headers: { 'HTTP_ORIGIN' => 'https://evil.example' })[0]).to eq(403)
      end
    end

    context 'with server_info' do
      let(:options) { { server_info: { name: 'Onetime Secret', version: '0.24.0' } } }

      it 'reports it from initialize' do
        expect(legacy_call('initialize')[2].dig('result', 'serverInfo')).to eq('name' => 'Onetime Secret', 'version' => '0.24.0')
      end
    end
  end

  describe 'an endpoint that serves both revisions' do
    let(:options) { { protocol_versions: %w[2026-07-28 2024-11-05] } }

    it 'serves a request that declares nothing as 2024-11-05' do
      expect(legacy_call('initialize')[2].dig('result', 'protocolVersion')).to eq('2024-11-05')
      expect(legacy_call('tools/list')[2]['result']).not_to have_key('resultType')
      expect(legacy_call('tools/call', { 'name' => 'echo', 'arguments' => { 'message' => 'hi' } })[2]['result'])
        .to eq('content' => [{ 'type' => 'text', 'text' => 'echo:hi' }])
    end

    it 'serves a request that declares 2026-07-28 under that revision' do
      result = modern_call(otto, 'tools/list')[2]['result']

      expect(result).to include('resultType' => 'complete', 'ttlMs' => 0)
    end

    it 'serves a request whose header names 2024-11-05 as 2024-11-05' do
      body = legacy_call('tools/list', {}, headers: { 'HTTP_MCP_PROTOCOL_VERSION' => '2024-11-05' })[2]

      expect(body['result']).not_to have_key('resultType')
    end

    it 'goes by the version in _meta when there is no header' do
      status, _headers, body = modern_call(otto, 'tools/list', {}, headers: { 'HTTP_MCP_PROTOCOL_VERSION' => nil })

      expect(status).to eq(400)
      expect(body.dig('error', 'code')).to eq(-32_020)
    end

    context 'with a version it does not serve' do
      let(:mcp_version) { '2025-11-25' }

      it 'answers under 2026-07-28 with every version it serves' do
        status, _headers, body = modern_call(otto, 'tools/list')

        expect(status).to eq(400)
        expect(body['error']).to include('code' => -32_022,
          'data' => { 'supported' => %w[2026-07-28 2024-11-05], 'requested' => '2025-11-25' })
      end
    end

    it 'checks Origin on requests of either revision' do
      expect(legacy_call('tools/list', {}, headers: { 'HTTP_ORIGIN' => 'https://evil.example' })[0]).to eq(403)
      expect(modern_call(otto, 'tools/list', {}, headers: { 'HTTP_ORIGIN' => 'https://evil.example' })[0]).to eq(403)
    end

    it 'answers 405 to GET' do
      expect(otto.call(Rack::MockRequest.env_for('/mcp', method: 'GET')).first).to eq(405)
    end
  end

  describe '2024-11-05 with an authenticator and declared tools' do
    let(:tokens) do
      { 'token-reader' => { subject: 'cust_reader', client_id: 'client_a', scopes: 'handoff:read' },
        'token-writer' => { subject: 'cust_writer', client_id: 'client_a', scopes: 'handoff:read handoff:write' } }
    end
    let(:options) do
      known = tokens
      { allow_unauthenticated: false,
                authenticator: ->(token, _env) { (found = known[token]) && Otto::MCP::Auth::Context.new(**found) } }
    end
    let(:seen) { [] }

    before do
      otto.register_mcp_tool('write', description: 'Write.', scopes: %w[handoff:write],
        input_schema: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
        output_schema: { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'] }) do |arguments, env|
        seen << [arguments, env['otto.mcp.auth'].subject, env['otto.mcp.call'].protocol_version]
        { ok: true }
      end
      otto.register_mcp_tool('asks', description: 'Asks.', input_schema: { type: 'object' }) do |_arguments, _env|
        Otto::MCP::InputRequired.url('k', url: 'https://example.com/enter', message: 'Enter it.')
      end
      otto.register_mcp_resource('docs/private', -> { 'private' }, description: 'Private', scopes: %w[handoff:write])
    end

    def bearer(token)
      { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }
    end

    it 'answers 401 with a challenge when there is no valid token' do
      status, headers, body = legacy_call('tools/list')

      expect(status).to eq(401)
      expect(headers['www-authenticate']).to eq('Bearer')
      expect(body).not_to have_key('id')
      expect(legacy_call('tools/list', {}, headers: bearer('nope'))[1]['www-authenticate']).to eq('Bearer error="invalid_token"')
    end

    it 'lists only the tools and resources the caller\'s scopes cover' do
      expect(legacy_call('tools/list', {}, headers: bearer('token-reader'))[2].dig('result', 'tools').map { |tool| tool['name'] })
        .to eq(%w[echo asks])
      expect(legacy_call('tools/list', {}, headers: bearer('token-writer'))[2].dig('result', 'tools').map { |tool| tool['name'] })
        .to eq(%w[echo write asks])
      expect(legacy_call('resources/list', {}, headers: bearer('token-reader'))[2].dig('result', 'resources')).to be_empty
    end

    it 'answers 403 to a call or a read the caller lacks a scope for' do
      status, headers, body = legacy_call('tools/call', { 'name' => 'write', 'arguments' => { 'id' => 'a' } }, headers: bearer('token-reader'))

      expect(status).to eq(403)
      expect(headers['www-authenticate']).to eq('Bearer error="insufficient_scope", scope="handoff:write"')
      expect(body['error']).to include('message' => 'Forbidden', 'data' => { 'requiredScopes' => %w[handoff:write] })
      expect(seen).to be_empty
      expect(legacy_call('resources/read', { 'uri' => 'docs/private' }, headers: bearer('token-reader'))[0]).to eq(403)
    end

    it 'validates arguments and returns structured content for a declared tool' do
      invalid = legacy_call('tools/call', { 'name' => 'write', 'arguments' => { 'id' => 7 } }, headers: bearer('token-writer'))[2]
      valid   = legacy_call('tools/call', { 'name' => 'write', 'arguments' => { 'id' => 'a' } }, headers: bearer('token-writer'))[2]

      expect(invalid['result']).to include('isError' => true)
      expect(valid['result']).to eq('content' => [{ 'type' => 'text', 'text' => '{"ok":true}' }], 'structuredContent' => { 'ok' => true })
      expect(seen).to eq([[{ 'id' => 'a' }, 'cust_writer', '2024-11-05']])
    end

    it 'tells the model that a tool needing input cannot run under this revision' do
      result = legacy_call('tools/call', { 'name' => 'asks' }, headers: bearer('token-reader'))[2]['result']

      expect(result).to eq('content' => [{ 'type' => 'text', 'text' => 'This tool needs a client that supports MCP 2026-07-28.' }],
        'isError' => true)
    end
  end

  describe 'static tokens' do
    let(:options) { { allow_unauthenticated: false, auth_tokens: ['static-token'] } }

    it 'answer 401 exactly as before, with no challenge header' do
      status, headers, body = legacy_call('tools/list')

      expect(status).to eq(401)
      expect(headers).not_to have_key('www-authenticate')
      expect(body).to eq('jsonrpc' => '2.0', 'id' => nil,
        'error' => { 'code' => -32_000, 'message' => 'Unauthorized', 'data' => 'Valid token required' })
    end

    it 'name no caller, so a tool cannot require scopes on such an endpoint' do
      expect do
        otto.register_mcp_tool('write', ->(_a, _e) {}, description: 'W', input_schema: { type: 'object' }, scopes: %w[handoff:write])
      end.to raise_error(ArgumentError, /requires scopes handoff:write, but this endpoint has no authenticator/)
    end
  end

  describe 'middleware order' do
    let(:options) do
      { protocol_versions: '2026-07-28', allow_unauthenticated: false, auth_tokens: ['static-token'], enable_rate_limiting: true }
    end

    it 'limits rate, then checks Origin, then authenticates, then validates' do
      mcp = [Otto::MCP::RateLimitMiddleware, Otto::MCP::OriginGuard, Otto::MCP::Auth::TokenMiddleware,
             Otto::MCP::SchemaValidationMiddleware]

      expect(otto.middleware.execution_order.select { |middleware| mcp.include?(middleware) }).to eq(mcp)
    end

    it 'refuses a bad Origin before it asks for a token' do
      expect(modern_call(otto, 'tools/list', {}, headers: { 'HTTP_ORIGIN' => 'https://evil.example' })[0]).to eq(403)
      expect(modern_call(otto, 'tools/list')[0]).to eq(401)
    end
  end
end
