# spec/otto/mcp/hosted_endpoint_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# A hosted MCP endpoint, end to end through otto.call: an authenticator that
# names the caller, tools with scopes and schemas, and a tool that sends the
# person to a page instead of taking a secret through the conversation.
RSpec.describe 'a hosted MCP endpoint' do # rubocop:disable RSpec/DescribeClass -- end-to-end behaviour of several classes
  include_context 'with rack attack isolation'
  include_context 'with mcp 2026-07-28 requests'

  let(:resource_uri) { 'https://mcp.example.com/mcp' }
  let(:log)          { StringIO.new }

  # token => who the authorization server says it belongs to
  let(:tokens) do
    {
      'token-requester' => { subject: 'cust_requester', client_id: 'client_a', tenant: 'org_1', scopes: 'handoff:write handoff:read' },
      'token-reader' => { subject: 'cust_reader', client_id: 'client_a', tenant: 'org_1', scopes: 'handoff:read' },
      'token-requester-other-client' => { subject: 'cust_requester', client_id: 'client_b', tenant: 'org_1',
                                          scopes: 'handoff:write handoff:read' },
      'token-other-tenant' => { subject: 'cust_requester', client_id: 'client_a', tenant: 'org_2', scopes: 'handoff:write handoff:read' },
      'token-for-another-service' => { subject: 'cust_requester', client_id: 'client_a', scopes: 'handoff:write',
                                       audience: 'https://api.example.com' },
    }
  end
  let(:authenticator) do
    known = tokens
    uri   = resource_uri
    ->(token, _env) { (attributes = known[token]) && Otto::MCP::Auth::Context.new(audience: uri, **attributes) }
  end
  let(:hosted_options) do
    { hosted: true, http_endpoint: '/mcp', authenticator: authenticator, resource_uri: resource_uri,
      authorization_servers: ['https://auth.example.com'], scopes_supported: %w[handoff:read],
      request_state_secret: 'request-state-secret-0123456789abcdef', enable_rate_limiting: false }
  end
  let(:operations) { {} }
  let(:handler_calls) { [] }
  let(:url_capable) { { 'elicitation' => { 'url' => {} } } }
  let(:otto) { build_hosted }

  around do |example|
    previous    = Otto.logger
    Otto.logger = Logger.new(log)
    example.run
  ensure
    Otto.logger = previous
  end

  def status_schema
    { type: 'object', additionalProperties: false, required: %w[operation_id state],
      properties: { operation_id: { type: 'string' }, state: { enum: %w[awaiting_input queued revealed] } } }
  end

  # The application side of a handoff: the first call opens an operation and
  # sends the person to a page, the retry reports where the operation stands.
  def arrange(arguments, env)
    call = env['otto.mcp.call']
    handler_calls << { arguments: arguments, subject: call.auth.subject, retry: call.retry?, state: call.state,
                       action: call.input_action('handoff') }
    return { operation_id: call.state['operation_id'], state: operations.fetch(call.state['operation_id']) } if call.retry?
    raise Otto::MCP::ToolError, 'Open your requests inbox to continue.' unless call.url_elicitation?

    id             = "op_#{operations.size + 1}"
    operations[id] = 'awaiting_input'
    Otto::MCP::InputRequired.url('handoff', url: "https://example.com/handoffs/#{id}", message: 'Enter the secret on example.com.',
      state: { 'operation_id' => id })
  end

  def build_hosted(**overrides)
    create_minimal_otto.tap do |app|
      app.enable_mcp!(**hosted_options, **overrides)
      app.register_mcp_tool('arrange_secret_delivery', method(:arrange), description: 'Hand a secret to a recipient.',
        input_schema: { type: 'object', properties: { recipient_ref: { type: 'string' } }, required: ['recipient_ref'] },
        output_schema: status_schema, scopes: %w[handoff:write])
      app.register_mcp_tool('get_delivery_status', description: 'Report where a handoff stands.',
        input_schema: { type: 'object', properties: { operation_id: { type: 'string' } }, required: ['operation_id'] },
        output_schema: status_schema, scopes: %w[handoff:read]) do |arguments, _env|
        { operation_id: arguments['operation_id'], state: operations.fetch(arguments['operation_id'], 'queued') }
      end
    end
  end

  def call(method_name, params = {}, token: 'token-requester', **)
    modern_call(otto, method_name, params, token: token, **)
  end

  def arrange_params(recipient: 'cust_recipient', **extra)
    { 'name' => 'arrange_secret_delivery', 'arguments' => { 'recipient_ref' => recipient } }.merge(extra)
  end

  describe 'enabling' do
    it 'requires an authenticator, a resource URI and authorization servers' do
      expect { create_minimal_otto.enable_mcp!(hosted: true) }
        .to raise_error(ArgumentError, 'MCP hosted: true requires authenticator, resource_uri, authorization_servers')
    end

    it 'serves 2026-07-28 only' do
      expect(otto.mcp_server.protocol.settings.protocol_versions).to eq(%w[2026-07-28])
      expect(otto.mcp_server).to be_hosted
    end

    it 'does not warn that the endpoint is unauthenticated' do
      otto

      expect(log.string).not_to include('enabled without authentication')
    end

    it 'can be enabled from Otto.new with the mcp_ spellings' do
      app = Otto.new(nil, mcp_enabled: true, mcp_hosted: true, mcp_endpoint: '/mcp', mcp_authenticator: authenticator,
        mcp_resource_uri: resource_uri, mcp_authorization_servers: ['https://auth.example.com'], mcp_rate_limiting: false)

      expect(app.mcp_server).to be_hosted
      expect(modern_call(app, 'server/discover', {}, token: 'token-reader')[0]).to eq(200)
    end
  end

  describe 'registering tools and resources' do
    let(:definition) { { description: 'A tool.', input_schema: { type: 'object' }, output_schema: { type: 'object' }, scopes: [] } }

    it 'requires a tool to state its output schema and its scopes' do
      expect { otto.register_mcp_tool('t', ->(_a, _e) {}, **definition.except(:output_schema, :scopes)) }
        .to raise_error(ArgumentError, /must state output_schema: and scopes:.*scopes: \[\] admits every authenticated caller/)
      expect { otto.register_mcp_tool('t', ->(_a, _e) {}, **definition.except(:scopes)) }
        .to raise_error(ArgumentError, /must state scopes:/)
    end

    it 'accepts scopes: [] as an explicit statement that any authenticated caller may use the tool' do
      otto.register_mcp_tool('whoami', ->(_a, env) { { subject: env['otto.mcp.auth'].subject } }, **definition)

      expect(call('tools/call', { 'name' => 'whoami' }, token: 'token-reader')[2].dig('result', 'structuredContent'))
        .to eq('subject' => 'cust_reader')
    end

    it 'requires a resource to state its scopes' do
      expect { otto.register_mcp_resource('docs/a', -> { 'a' }, description: 'A') }.to raise_error(ArgumentError, /must state scopes:/)
    end

    it 'refuses a TOOL route line, which cannot state schemas or scopes' do
      routes = create_test_routes_file('hosted_mcp_tool_routes.txt', ['POST /mcp/echo TOOL echo TestMCPTool.echo'])

      expect { otto.load(routes) }.to raise_error(Otto::RouteDefinitionError, /TOOL route "echo" cannot be loaded on a hosted MCP endpoint/)
    end

    it 'refuses an MCP resource route line' do
      routes = create_test_routes_file('hosted_mcp_resource_routes.txt', ['GET /mcp/users MCP users TestMCPTool.echo'])

      expect { otto.load(routes) }.to raise_error(Otto::RouteDefinitionError, /MCP route "users" cannot be loaded/)
    end

    # Otto freezes its configuration at the first request. Under RSpec that
    # step is skipped, so the example takes it explicitly.
    it 'cannot change once the configuration is frozen' do
      app = Otto.new
      app.enable_mcp!(**hosted_options)
      app.freeze_configuration!

      expect { app.register_mcp_tool('late', ->(_a, _e) {}, **definition) }.to raise_error(FrozenError)
      expect { app.mcp_server.define_tool('late', ->(_a, _e) {}, **definition) }.to raise_error(FrozenError)
      expect { app.mcp_server.protocol.registry.register_tool('late', 'Late', {}, ->(_a, _e) {}) }.to raise_error(FrozenError)
      expect(modern_call(app, 'tools/list', {}, token: 'token-reader')[0]).to eq(200)
    end
  end

  describe 'authentication' do
    let(:metadata_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

    it 'answers 401 with where to find the authorization servers when there is no token' do
      status, headers, body = call('tools/list', {}, token: nil)

      expect(status).to eq(401)
      expect(headers['www-authenticate']).to eq(%(Bearer scope="handoff:read", resource_metadata="#{metadata_url}"))
      expect(body).to eq('jsonrpc' => '2.0', 'error' => { 'code' => 401, 'message' => 'Unauthorized', 'data' => 'Valid token required' })
    end

    it 'answers 401 invalid_token to a token the authenticator does not know' do
      status, headers, = call('tools/list', {}, token: 'not-a-token')

      expect(status).to eq(401)
      expect(headers['www-authenticate']).to start_with('Bearer error="invalid_token"')
    end

    # "MCP servers MUST validate that access tokens were issued specifically
    # for them as the intended audience".
    it 'answers 401 to a token the authenticator accepts but that was issued for another service' do
      status, headers, = call('tools/list', {}, token: 'token-for-another-service')

      expect(status).to eq(401)
      expect(headers['www-authenticate']).to include('error="invalid_token"')
      expect(log.string).to include('MCP token not issued for this endpoint')
    end

    it 'reads the token from the Authorization header only' do
      status, = call('tools/list', {}, token: nil, headers: { 'HTTP_X_MCP_TOKEN' => 'token-requester' })
      expect(status).to eq(401)

      env = modern_env('tools/list', {}, path: '/mcp?access_token=token-requester')
      expect(otto.call(env).first).to eq(401)
    end

    it 'authenticates every method, including discovery' do
      %w[server/discover tools/list resources/list].each do |method_name|
        expect(call(method_name, {}, token: nil)[0]).to eq(401)
        expect(call(method_name, {}, token: 'token-reader')[0]).to eq(200)
      end
    end

    it 'runs no tool handler for an unauthenticated call' do
      call('tools/call', arrange_params, token: nil, capabilities: url_capable)

      expect(handler_calls).to be_empty
      expect(operations).to be_empty
    end

    it 'answers 401 before reading a malformed request' do
      env = modern_env('tools/list')
      env['rack.input'] = StringIO.new('{not json')

      expect(otto.call(env).first).to eq(401)
    end

    it 'reports a failing authenticator as a server error, never as a refusal or a success' do
      app = build_hosted(authenticator: ->(_token, _env) { raise IOError, 'token store unreachable' })

      status, _headers, body = app.call(modern_env('tools/list', {}, token: 'token-requester'))

      expect(status).to eq(500)
      expect(body.to_a.join).not_to include('token store unreachable')
    end

    it 'refuses to serve a request the authentication middleware did not vouch for' do
      env = modern_env('tools/list', {}, token: 'token-requester')
      env['otto.mcp.auth'] = nil
      status, headers, = otto.mcp_server.protocol.handle_request(env)

      expect(status).to eq(401)
      expect(headers['www-authenticate']).to include('resource_metadata=')
    end
  end

  describe 'the protected resource metadata document' do
    it 'is served without a token at the well-known path beside the endpoint' do
      status, headers, body = otto.call(Rack::MockRequest.env_for('/.well-known/oauth-protected-resource/mcp'))

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/json')
      expect(JSON.parse(body.to_a.join)).to eq(
        'resource' => resource_uri,
        'authorization_servers' => ['https://auth.example.com'],
        'scopes_supported' => %w[handoff:read],
        'bearer_methods_supported' => ['header']
      )
    end

    it 'is available to an application that serves it from somewhere else' do
      expect(otto.mcp_server.protected_resource_metadata).to include('resource' => resource_uri).and be_frozen
    end

    it 'is absent from an endpoint that has no resource URI' do
      app = create_minimal_otto.tap { |plain| plain.enable_mcp!(allow_unauthenticated: true, enable_rate_limiting: false) }

      expect(app.mcp_server.protected_resource_metadata).to be_nil
      expect(app.call(Rack::MockRequest.env_for('/.well-known/oauth-protected-resource/_mcp')).first).to eq(404)
    end
  end

  describe 'what a caller can list' do
    it 'is limited to the tools its scopes cover' do
      expect(call('tools/list', {}, token: 'token-requester')[2].dig('result', 'tools').map { |tool| tool['name'] })
        .to eq(%w[arrange_secret_delivery get_delivery_status])
      expect(call('tools/list', {}, token: 'token-reader')[2].dig('result', 'tools').map { |tool| tool['name'] })
        .to eq(%w[get_delivery_status])
    end

    it 'is marked private, so a client does not reuse one caller\'s list for another' do
      expect(call('tools/list')[2].dig('result', 'cacheScope')).to eq('private')
    end

    it 'never includes the scopes or the handler' do
      expect(call('tools/list')[2].dig('result', 'tools').flat_map(&:keys).uniq)
        .to contain_exactly('name', 'description', 'inputSchema', 'outputSchema')
    end
  end

  describe 'calling a tool the caller lacks a scope for' do
    it 'answers 403 naming the scopes, though the tool was left out of its list' do
      status, headers, body = call('tools/call', arrange_params, token: 'token-reader', capabilities: url_capable)

      expect(status).to eq(403)
      expect(headers['www-authenticate']).to eq(
        'Bearer error="insufficient_scope", scope="handoff:write", ' \
        'resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp"'
      )
      expect(body).to eq('jsonrpc' => '2.0', 'id' => 1,
        'error' => { 'code' => 403, 'message' => 'Forbidden', 'data' => { 'requiredScopes' => %w[handoff:write] } })
      expect(handler_calls).to be_empty
      expect(log.string).to include('MCP call refused: insufficient scope', 'arrange_secret_delivery', 'client_a')
    end

    it 'does the same for a resource' do
      otto.register_mcp_resource('handoffs/policy', -> { 'policy' }, description: 'Policy', scopes: %w[handoff:write])

      expect(call('resources/list', {}, token: 'token-reader')[2].dig('result', 'resources')).to be_empty
      expect(call('resources/read', { 'uri' => 'handoffs/policy' }, token: 'token-reader')[0]).to eq(403)
      expect(call('resources/read', { 'uri' => 'handoffs/policy' }, token: 'token-requester')[0]).to eq(200)
    end
  end

  describe 'handing a secret off through a page' do
    let(:secret) { 'correct-horse-battery-staple' }

    def first_call(**)
      call('tools/call', arrange_params, capabilities: url_capable, **)
    end

    def retry_params(state, **extra)
      arrange_params('inputResponses' => { 'handoff' => { 'action' => 'accept' } }, 'requestState' => state, **extra)
    end

    it 'answers the first call with a URL request and an opaque state' do
      status, _headers, body = first_call

      expect(status).to eq(200)
      expect(body['result']).to include(
        'resultType' => 'input_required',
        'inputRequests' => { 'handoff' => { 'method' => 'elicitation/create', 'params' => {
          'mode' => 'url', 'url' => 'https://example.com/handoffs/op_1', 'message' => 'Enter the secret on example.com.'
        } } }
      )
      expect(body['result']).not_to include('ttlMs', 'cacheScope', 'content')
      expect(body.dig('result', 'requestState')).to match(/\Av1\.[A-Za-z0-9_-]+\z/)
      expect(body.dig('result', 'requestState')).not_to include('op_1')
    end

    it 'returns the state to the handler when the same caller retries the same call' do
      state = first_call[2].dig('result', 'requestState')
      operations['op_1'] = 'queued' # the person submitted the page

      status, _headers, body = call('tools/call', retry_params(state), id: 2)

      expect(status).to eq(200)
      expect(body.dig('result', 'structuredContent')).to eq('operation_id' => 'op_1', 'state' => 'queued')
      expect(handler_calls.last).to include(retry: true, state: { 'operation_id' => 'op_1' }, action: 'accept',
        subject: 'cust_requester')
    end

    # "It does not mean that the interaction is complete."
    it 'leaves it to the application to say whether the person finished' do
      state = first_call[2].dig('result', 'requestState')

      body = call('tools/call', retry_params(state), id: 2)[2]

      expect(body.dig('result', 'structuredContent', 'state')).to eq('awaiting_input')
    end

    it 'treats a call without a state as a first call, whatever responses it claims' do
      call('tools/call', arrange_params('inputResponses' => { 'handoff' => { 'action' => 'accept' } }), capabilities: url_capable)

      expect(handler_calls.last).to include(retry: false, state: nil)
    end

    {
      'another person' => { token: 'token-reader' },
      'the same person through another client' => { token: 'token-requester-other-client' },
      'the same person in another tenant' => { token: 'token-other-tenant' },
    }.each do |label, request|
      it "refuses the state when #{label} presents it" do
        state  = first_call[2].dig('result', 'requestState')
        before = handler_calls.size
        otto.register_mcp_tool('probe', ->(_a, _e) { {} }, description: 'P', input_schema: { type: 'object' },
          output_schema: { type: 'object' }, scopes: [])

        status, _headers, body = call('tools/call', { 'name' => 'probe', 'requestState' => state }, **request)

        expect(status).to eq(400)
        expect(body['error']).to eq('code' => -32_602, 'message' => 'Invalid params',
          'data' => 'requestState was not issued for this request')
        expect(handler_calls.size).to eq(before)
      end
    end

    it 'refuses the state on a call with other arguments' do
      state = first_call[2].dig('result', 'requestState')

      status, = call('tools/call', retry_params(state, 'arguments' => { 'recipient_ref' => 'cust_attacker' }), id: 2)

      expect(status).to eq(400)
      expect(handler_calls.size).to eq(1)
    end

    it 'refuses the state on a call to another tool' do
      state = first_call[2].dig('result', 'requestState')

      status, = call('tools/call', { 'name' => 'get_delivery_status', 'arguments' => { 'operation_id' => 'op_1' },
                                     'requestState' => state })

      expect(status).to eq(400)
    end

    it 'refuses a state that was altered, or is not one' do
      state = first_call[2].dig('result', 'requestState')

      ["#{state[0..-5]}AAAA", 'v1.AAAA', 'eyJvcGVyYXRpb25faWQiOiJvcF8xIn0', 42].each do |forged|
        expect(call('tools/call', retry_params(forged), id: 2)[0]).to eq(400)
      end
      expect(handler_calls.size).to eq(1)
    end

    it 'refuses a state that has expired' do
      state = first_call[2].dig('result', 'requestState')

      allow(Time).to receive(:now).and_return(Time.now + Otto::MCP::InputRequired::DEFAULT_TTL + 1)

      expect(call('tools/call', retry_params(state), id: 2)[0]).to eq(400)
    end

    it 'accepts the state on any process that has the same secret' do
      state = first_call[2].dig('result', 'requestState')
      other = build_hosted

      status, = modern_call(other, 'tools/call', retry_params(state), token: 'token-requester', id: 2)

      expect(status).to eq(200)
    end

    # "Servers MUST NOT send an inputRequests that the client has not
    # declared support for in its capabilities."
    it 'answers 400 MissingRequiredClientCapability when the client cannot open a URL' do
      otto.register_mcp_tool('always_asks', description: 'Asks.', input_schema: { type: 'object' },
        output_schema: { type: 'object' }, scopes: []) do |_arguments, _env|
        Otto::MCP::InputRequired.url('k', url: 'https://example.com/enter', message: 'Enter it.')
      end

      [{}, { 'elicitation' => {} }, { 'elicitation' => { 'form' => {} } }].each do |capabilities|
        status, _headers, body = call('tools/call', { 'name' => 'always_asks' }, capabilities: capabilities)

        expect(status).to eq(400)
        expect(body['error']).to include('code' => -32_021, 'data' => { 'requiredCapabilities' => { 'elicitation' => { 'url' => {} } } })
        expect(body.to_s).not_to include('example.com/enter')
      end
    end

    it 'lets the handler choose another route for a client that cannot open a URL' do
      body = call('tools/call', arrange_params)[2]

      expect(body['result']).to include('isError' => true, 'content' => [{ 'type' => 'text', 'text' => 'Open your requests inbox to continue.' }])
    end

    it 'never puts a secret a caller sent in a response or a log' do
      responses = [
        call('tools/call', arrange_params('arguments' => { 'recipient_ref' => 'cust_recipient', 'secret' => secret })),
        call('tools/call', arrange_params('arguments' => { 'recipient_ref' => secret * 2, 'value' => { 'nested' => secret } })),
        call('tools/call', { 'name' => 'get_delivery_status', 'arguments' => { 'operation_id' => 7, secret => secret } }),
        call('tools/call', retry_params(secret), id: 2),
      ]

      expect(responses.map { |response| response[2].dig('result', 'isError') || response[0] }).to eq([true, true, true, 400])
      expect(handler_calls.map { |entry| entry[:arguments].to_s }.join).not_to include(secret)
      expect(log.string).not_to include(secret)
      expect(responses.map { |response| response[2].to_s }.join.scan(secret).size).to eq(1) # the property name it was sent as
    end

    it 'never logs a bearer token' do
      first_call
      call('tools/list', {}, token: 'not-a-token')
      call('tools/list', {}, token: 'token-for-another-service')
      call('tools/call', arrange_params, token: 'token-reader')

      expect(log.string).not_to match(/token-(requester|reader|for-another-service)|not-a-token/)
    end

    context 'without a request_state_secret' do
      let(:hosted_options) { super().except(:request_state_secret) }

      it 'warns the first time it issues a state, and only then' do
        call('tools/list')
        expect(log.string).not_to include('request_state_secret is not set')

        2.times { first_call }
        expect(log.string.scan('request_state_secret is not set').size).to eq(1)
      end

      it 'refuses on one process a state another process issued' do
        state = first_call[2].dig('result', 'requestState')

        status, = modern_call(build_hosted, 'tools/call', retry_params(state), token: 'token-requester', id: 2)

        expect(status).to eq(400)
      end
    end
  end

  describe 'two endpoints in one process' do
    let(:english_tokens) { { 'token-en' => { subject: 'cust_en', scopes: 'greet' } } }
    let(:french_tokens)  { { 'token-fr' => { subject: 'cust_fr', scopes: 'greet' } } }
    let(:app) do
      Rack::URLMap.new(
        '/en' => greeter(english_tokens, 'https://mcp.example.com/en/mcp', 'Hello'),
        '/fr' => greeter(french_tokens, 'https://mcp.example.com/fr/mcp', 'Bonjour')
      )
    end

    def greeter(tokens, resource, greeting)
      create_minimal_otto.tap do |app|
        app.enable_mcp!(hosted: true, http_endpoint: '/mcp', enable_rate_limiting: false, resource_uri: resource,
          authorization_servers: ['https://auth.example.com'],
          authenticator: ->(token, _env) { (found = tokens[token]) && Otto::MCP::Auth::Context.new(audience: resource, **found) })
        app.register_mcp_tool('greet', description: 'Greet.', input_schema: { type: 'object' },
          output_schema: { type: 'object' }, scopes: %w[greet]) do |_arguments, env|
          { greeting: greeting, subject: env['otto.mcp.auth'].subject }
        end
      end
    end

    it 'reach their own tools with their own callers' do
      [['/en/mcp', 'token-en', 'Hello', 'cust_en'], ['/fr/mcp', 'token-fr', 'Bonjour', 'cust_fr']].each do |path, token, greeting, subject|
        status, _headers, body = modern_call(app, 'tools/call', { 'name' => 'greet' }, token: token, path: path)

        expect(status).to eq(200)
        expect(body.dig('result', 'structuredContent')).to eq('greeting' => greeting, 'subject' => subject)
      end
    end

    it 'do not accept each other\'s tokens' do
      expect(modern_call(app, 'tools/call', { 'name' => 'greet' }, token: 'token-fr', path: '/en/mcp')[0]).to eq(401)
      expect(modern_call(app, 'tools/call', { 'name' => 'greet' }, token: 'token-en', path: '/fr/mcp')[0]).to eq(401)
    end

    it 'name their own metadata document in a challenge' do
      english = modern_call(app, 'tools/list', {}, path: '/en/mcp')[1]['www-authenticate']
      french  = modern_call(app, 'tools/list', {}, path: '/fr/mcp')[1]['www-authenticate']

      expect(english).to include('https://mcp.example.com/.well-known/oauth-protected-resource/en/mcp')
      expect(french).to include('https://mcp.example.com/.well-known/oauth-protected-resource/fr/mcp')
    end
  end

  describe 'a caller placed in env by something other than the authenticator' do
    let(:forged) { Otto::MCP::Auth::Context.new(subject: 'cust_forged', scopes: 'handoff:write handoff:read', audience: resource_uri) }

    it 'is replaced by the authenticator\'s answer on an authenticated endpoint' do
      env = modern_env('tools/call', arrange_params, token: 'token-reader', capabilities: url_capable)
      env['otto.mcp.auth'] = forged

      expect(otto.call(env).first).to eq(403)

      anonymous = modern_env('tools/list')
      anonymous['otto.mcp.auth'] = forged
      expect(otto.call(anonymous).first).to eq(401)
    end

    it 'is discarded by an endpoint that has no authenticator' do
      seen = :unset
      open = create_minimal_otto.tap do |app|
        app.enable_mcp!(http_endpoint: '/mcp', protocol_versions: '2026-07-28', allow_unauthenticated: true, enable_rate_limiting: false)
        app.register_mcp_tool('who', description: 'Who.', input_schema: { type: 'object' }) do |_arguments, env|
          seen = [env['otto.mcp.auth'], env['otto.mcp.call'].auth]
          'ok'
        end
      end
      env = modern_env('tools/call', { 'name' => 'who' })
      env['otto.mcp.auth'] = forged

      open.call(env)

      expect(seen).to eq([nil, nil])
    end
  end
end
