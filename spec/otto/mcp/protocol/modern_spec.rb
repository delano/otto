# spec/otto/mcp/protocol/modern_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# MCP revision 2026-07-28 over the HTTP endpoint, driven through otto.call.
# Requirements quoted in the examples are from the specification at
# https://github.com/modelcontextprotocol/modelcontextprotocol/tree/bd5bc16fb0b4eee9e0a1994ffaa1d67f213865ac/docs/specification/2026-07-28
RSpec.describe Otto::MCP::Protocol::Modern do
  include_context 'with rack attack isolation'
  include_context 'with mcp 2026-07-28 requests'

  let(:options) { {} }
  let(:log)     { StringIO.new }
  let(:otto) do
    create_minimal_otto.tap do |app|
      app.enable_mcp!(http_endpoint: '/mcp', protocol_versions: '2026-07-28', allow_unauthenticated: true,
                          enable_rate_limiting: false, **options)
    end
  end
  let(:server_info) { { 'io.modelcontextprotocol/serverInfo' => { 'name' => 'Otto MCP Server', 'version' => Otto::VERSION } } }

  around do |example|
    previous    = Otto.logger
    Otto.logger = Logger.new(log)
    example.run
  ensure
    Otto.logger = previous
  end

  def call(method_name, params = {}, **)
    modern_call(otto, method_name, params, **)
  end

  def error_of(response)
    [response[0], response[2].dig('error', 'code')]
  end

  describe 'server/discover' do
    it 'reports the versions, capabilities and identity of the endpoint' do
      status, headers, body = call('server/discover')

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/json')
      expect(body).to eq(
        'jsonrpc' => '2.0', 'id' => 1,
        'result' => {
          'resultType' => 'complete',
          'supportedVersions' => ['2026-07-28'],
          'capabilities' => { 'tools' => {}, 'resources' => {} },
          'ttlMs' => 0,
          'cacheScope' => 'public',
          '_meta' => server_info,
        }
      )
    end

    context 'with server_info, instructions and cache_ttl_ms' do
      let(:options) do
        { server_info: { name: 'Onetime Secret', version: '0.24.0' }, instructions: 'Hand secrets off, never read them.',
          cache_ttl_ms: 300_000 }
      end

      it 'reports them' do
        result = call('server/discover')[2]['result']

        expect(result['_meta']).to eq('io.modelcontextprotocol/serverInfo' => { 'name' => 'Onetime Secret', 'version' => '0.24.0' })
        expect(result).to include('instructions' => 'Hand secrets off, never read them.', 'ttlMs' => 300_000)
      end
    end

    context 'when the endpoint also serves 2024-11-05' do
      let(:options) { { protocol_versions: %w[2024-11-05 2026-07-28] } }

      it 'lists every revision it serves, newest first' do
        expect(call('server/discover')[2].dig('result', 'supportedVersions')).to eq(%w[2026-07-28 2024-11-05])
      end
    end
  end

  describe 'request metadata' do
    # "Every POST request to the MCP endpoint MUST include an
    # MCP-Protocol-Version header."
    it 'answers 400 HeaderMismatch without MCP-Protocol-Version, naming what it serves' do
      status, _headers, body = call('tools/list', {}, headers: { 'HTTP_MCP_PROTOCOL_VERSION' => nil })

      expect(status).to eq(400)
      expect(body['error']).to eq(
        'code' => -32_020,
        'message' => 'Header mismatch: MCP-Protocol-Version header is required. Supported versions: 2026-07-28'
      )
    end

    # A 2025-11-25 or earlier client opens with initialize and sends none of
    # the 2026-07-28 headers. "A server that supports only modern versions
    # SHOULD name the protocol versions it supports in any error it returns
    # to an initialize request".
    it 'tells a client that opens with initialize which versions it serves' do
      env = Rack::MockRequest.env_for('/mcp', method: 'POST', 'CONTENT_TYPE' => 'application/json',
        input: JSON.generate({ jsonrpc: '2.0', id: 1, method: 'initialize',
                               params: { protocolVersion: '2025-11-25', capabilities: {} } }))

      status, _headers, body = otto.call(env)
      parsed                 = JSON.parse(body.to_a.join)

      expect(status).to eq(400)
      expect(parsed.dig('error', 'code')).to eq(-32_020)
      expect(parsed.dig('error', 'message')).to include('Supported versions: 2026-07-28')
    end

    it 'answers 400 HeaderMismatch when Mcp-Method is missing or differs from the body' do
      expect(error_of(call('tools/list', {}, headers: { 'HTTP_MCP_METHOD' => nil }))).to eq([400, -32_020])
      expect(error_of(call('tools/list', {}, headers: { 'HTTP_MCP_METHOD' => 'server/discover' }))).to eq([400, -32_020])
    end

    it 'answers 400 HeaderMismatch when the header version differs from the version in _meta' do
      response = call('tools/list', {}, meta: { 'io.modelcontextprotocol/protocolVersion' => '2025-11-25' })

      expect(error_of(response)).to eq([400, -32_020])
    end

    # "A request missing any required field is malformed; the server MUST
    # reject it with JSON-RPC error code -32602 (Invalid params). On HTTP,
    # the response status MUST be 400 Bad Request."
    it 'answers 400 Invalid params when _meta has no protocol version' do
      response = call('tools/list', {}, meta: { 'io.modelcontextprotocol/protocolVersion' => nil })

      expect(error_of(response)).to eq([400, -32_602])
      expect(response[2].dig('error', 'data')).to eq('Missing _meta io.modelcontextprotocol/protocolVersion')
    end

    it 'answers 400 Invalid params when _meta has no client capabilities' do
      response = call('tools/list', {}, meta: { 'io.modelcontextprotocol/clientCapabilities' => nil })

      expect(error_of(response)).to eq([400, -32_602])
      expect(response[2].dig('error', 'data')).to eq('Missing _meta io.modelcontextprotocol/clientCapabilities')
    end

    it 'answers 400 Invalid params when params is not an object' do
      env = modern_env('tools/list')
      env['rack.input'] = StringIO.new(JSON.generate({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: [1] }))

      status, _headers, body = otto.call(env)

      expect([status, JSON.parse(body.to_a.join).dig('error', 'code')]).to(satisfy { |pair| [[400, -32_602], [400, -32_600]].include?(pair) })
    end

    context 'with an unsupported version' do
      let(:mcp_version) { '2027-01-01' }

      # The version is settled before anything else the request lacks.
      it 'answers with UnsupportedProtocolVersion even when other headers or _meta are missing' do
        missing = call('tools/list', {}, headers: { 'HTTP_MCP_METHOD' => nil },
          meta: { 'io.modelcontextprotocol/protocolVersion' => nil, 'io.modelcontextprotocol/clientCapabilities' => nil })

        expect(error_of(missing)).to eq([400, -32_022])
      end

      # "it MUST respond with 400 Bad Request and an
      # UnsupportedProtocolVersionError listing its supported versions."
      it 'answers 400 with the versions it supports and the one requested' do
        status, _headers, body = call('tools/list')

        expect(status).to eq(400)
        expect(body['error']).to eq(
          'code' => -32_022,
          'message' => 'Unsupported protocol version',
          'data' => { 'supported' => ['2026-07-28'], 'requested' => '2027-01-01' }
        )
      end
    end

    it 'does not repeat back a version header that is not short printable ASCII' do
      [(+"2027\xFF").force_encoding(Encoding::UTF_8), "2027\xFF".b, 'v' * 200, "2027\n01"].each do |odd|
        status, _headers, body = call('tools/list', {}, headers: { 'HTTP_MCP_PROTOCOL_VERSION' => odd })

        expect(status).to eq(400)
        expect(body.dig('error', 'data', 'requested')).to eq('unrecognized')
      end
    end

    it 'adds its name and version to every result' do
      otto.mcp_server.protocol.registry.register_resource('docs/a', 'a', 'A', 'text/plain', -> { 'a' })

      [call('tools/list'), call('resources/list'), call('resources/read', { 'uri' => 'docs/a' })].each do |response|
        expect(response[2].dig('result', '_meta')).to eq(server_info)
        expect(response[2].dig('result', 'resultType')).to eq('complete')
      end
    end
  end

  describe 'the request envelope' do
    def raw(payload)
      env = modern_env('tools/list')
      env['rack.input'] = StringIO.new(payload.is_a?(String) ? payload : JSON.generate(payload))
      status, _headers, body = otto.call(env)
      [status, JSON.parse(body.to_a.join)]
    end

    malformed = {
      'a null id' => { jsonrpc: '2.0', id: nil, method: 'tools/list', params: {} },
      'no id, which makes it a notification' => { jsonrpc: '2.0', method: 'notifications/cancelled', params: {} },
      'a batch' => [{ jsonrpc: '2.0', id: 1, method: 'tools/list' }],
      'the wrong jsonrpc version' => { jsonrpc: '1.0', id: 1, method: 'tools/list' },
    }

    [true, false].each do |validation|
      context "with enable_validation: #{validation}" do
        let(:options) { { enable_validation: validation } }

        malformed.each do |label, payload|
          it "answers 400 Invalid Request to #{label}" do
            status, body = raw(payload)

            expect(status).to eq(400)
            expect(body.dig('error', 'code')).to eq(-32_600)
          end
        end

        it 'answers 400 Parse error to a body that is not JSON' do
          status, body = raw('{not json')

          expect(status).to eq(400)
          expect(body.dig('error', 'code')).to eq(validation ? -32_600 : -32_700)
        end
      end
    end

    it 'accepts a String id and returns it' do
      expect(call('tools/list', {}, id: 'req-7')[2]['id']).to eq('req-7')
    end

    # "Error responses MUST include the same ID as the request they
    # correspond to (except in error cases where the ID could not be read
    # due to a malformed request)."
    context 'with enable_validation: false' do
      let(:options) { { enable_validation: false } }

      it 'returns an id it could read, though the request is refused for something else' do
        expect(raw({ jsonrpc: '2.0', id: 'req-9' })).to match([400, include('id' => 'req-9')])
        expect(raw({ jsonrpc: '1.0', id: 12, method: 'tools/list' })).to match([400, include('id' => 12)])
      end
    end

    # 2026-07-28 has no null id, so an id that could not be read is left out.
    unreadable = ['{not json', '[1]', '7', '{"jsonrpc":"2.0","method":"tools/list"}',
                  '{"jsonrpc":"2.0","id":null,"method":"tools/list"}']

    [true, false].each do |validation|
      context "with enable_validation: #{validation}, when the id could not be read" do
        let(:options) { { enable_validation: validation } }

        unreadable.each do |payload|
          it "has no id member in the error for #{payload[0, 16]}" do
            status, body = raw(payload)

            expect(status).to eq(400)
            expect(body).not_to have_key('id')
          end
        end
      end
    end

    # Ruby's JSON parser accepts both of these, and each one used to raise
    # later: when the id was echoed, the arguments digested, or validated.
    describe 'a body the parser accepts but a response cannot be built from' do
      before do
        otto.register_mcp_tool('typed', ->(_a, _e) { 'ok' }, description: 'Typed.',
          input_schema: { type: 'object', properties: { n: { type: 'integer' } } })
      end

      validations = [true, false]

      {
        'a number that overflows to Infinity' => '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"typed","arguments":{"n":1e400}}}',
        'bytes that are not UTF-8 in the id' => "{\"jsonrpc\":\"2.0\",\"id\":\"a\xFF\",\"method\":\"tools/list\"}",
        'bytes that are not UTF-8 in a tool name' => "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"a\xFF\"}}",
      }.each do |label, payload|
        validations.each do |validation|
          context "with enable_validation: #{validation}" do
            let(:options) { { enable_validation: validation } }

            it "answers 400 to #{label}" do
              env = modern_env('tools/call', { 'name' => 'typed' })
              env['rack.input'] = StringIO.new(payload.b)

              status, _headers, body = otto.call(env)

              expect(status).to eq(400)
              expect(JSON.parse(body.to_a.join).dig('error', 'code')).to eq(validation ? -32_600 : -32_700)
              expect(log.string).not_to include('ERROR')
            end
          end
        end
      end
    end
  end

  describe 'methods' do
    # "If the server does not implement the requested RPC method, it MUST
    # respond with 404 Not Found and a JSON-RPC error with code -32601".
    %w[prompts/list subscriptions/listen ping logging/setLevel resources/subscribe].each do |method_name|
      it "answers 404 Method not found to #{method_name}" do
        expect(error_of(call(method_name))).to eq([404, -32_601])
      end
    end

    it 'answers 404 to initialize and names the versions it serves' do
      status, _headers, body = call('initialize')

      expect(status).to eq(404)
      expect(body.dig('error', 'data')).to eq('Supported versions: 2026-07-28')
    end

    it 'does not echo an unknown method name' do
      expect(call('x' * 500)[2].to_s).not_to include('xxxx')
    end
  end

  describe 'tools/list and resources/list' do
    before do
      otto.register_mcp_tool('alpha', ->(_a, _e) { 'a' }, description: 'Alpha', input_schema: { type: 'object' })
      otto.mcp_server.protocol.registry.register_tool('beta', 'Beta', { type: 'object' }, ->(_a, _e) { 'b' })
      otto.register_mcp_resource('docs/a', -> { 'a' }, description: 'A')
    end

    it 'returns the tools in registration order with caching hints' do
      result = call('tools/list')[2]['result']

      expect(result['tools'].map { |tool| tool['name'] }).to eq(%w[alpha beta])
      expect(result).to include('ttlMs' => 0, 'cacheScope' => 'public')
      expect(result).not_to have_key('nextCursor')
    end

    it 'returns the resources with caching hints' do
      result = call('resources/list')[2]['result']

      expect(result['resources']).to eq([{ 'uri' => 'docs/a', 'name' => 'a', 'description' => 'A', 'mimeType' => 'text/plain' }])
      expect(result).to include('ttlMs' => 0, 'cacheScope' => 'public')
    end

    it 'answers 400 Invalid params to a cursor, since it never issues one' do
      expect(error_of(call('tools/list', { 'cursor' => 'abc' }))).to eq([400, -32_602])
      expect(error_of(call('resources/list', { 'cursor' => 'abc' }))).to eq([400, -32_602])
    end
  end

  describe 'tools/call' do
    let(:output_schema) { { type: 'object', properties: { sum: { type: 'integer' } }, required: ['sum'], additionalProperties: false } }

    before do
      otto.register_mcp_tool('add', description: 'Add two integers.', output_schema: output_schema,
        input_schema: { type: 'object', properties: { a: { type: 'integer' }, b: { type: 'integer' } }, required: %w[a b] }) do |arguments, _env|
        { sum: arguments['a'] + arguments['b'] }
      end
      otto.register_mcp_tool('leaky', ->(_a, _e) { { sum: 1, password: 'hunter2' } }, description: 'Returns too much.',
        input_schema: { type: 'object' }, output_schema: output_schema)
      otto.register_mcp_tool('boom', ->(_a, _e) { raise 'db password is hunter2' }, description: 'Raises.',
        input_schema: { type: 'object' })
      otto.register_mcp_tool('asks', description: 'Needs input.', input_schema: { type: 'object' }) do |_arguments, _env|
        Otto::MCP::InputRequired.url('k', url: 'https://example.com/enter', message: 'Enter it.')
      end
      otto.mcp_server.protocol.registry.register_tool('echo', 'Echo', { type: 'object' }, 'TestMCPTool.echo')
    end

    it 'returns structured content and its JSON text for a tool with an output schema' do
      status, _headers, body = call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 2, 'b' => 3 } })

      expect(status).to eq(200)
      expect(body['result']).to eq(
        'resultType' => 'complete',
        'content' => [{ 'type' => 'text', 'text' => '{"sum":5}' }],
        'structuredContent' => { 'sum' => 5 },
        '_meta' => server_info
      )
    end

    it 'returns text for an undeclared tool' do
      result = call('tools/call', { 'name' => 'echo', 'arguments' => { 'message' => 'hi' } })[2]['result']

      expect(result).to include('resultType' => 'complete', 'content' => [{ 'type' => 'text', 'text' => 'echo:hi' }])
    end

    # "Invalid tool arguments are instead reported as tool execution errors,
    # with isError set to true" (schema.ts, InvalidParamsError).
    it 'reports invalid arguments as a tool error the model can read' do
      status, _headers, body = call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 'two', 'c' => 1 } })

      expect(status).to eq(200)
      expect(body.dig('result', 'isError')).to be(true)
      expect(body.dig('result', 'content', 0, 'text')).to include('Invalid arguments for tool add', '/a', '/c')
    end

    it 'answers 400 Invalid params to an unknown tool' do
      status, _headers, body = call('tools/call', { 'name' => 'nope' })

      expect(status).to eq(400)
      expect(body['error']).to eq('code' => -32_602, 'message' => 'Unknown tool: nope')
    end

    it 'answers 400 Invalid params when name or arguments has the wrong type' do
      expect(error_of(call('tools/call', {}))).to eq([400, -32_602])
      expect(error_of(call('tools/call', { 'name' => 'add', 'arguments' => [1, 2] }))).to eq([400, -32_602])
      expect(error_of(call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 1, 'b' => 2 }, 'inputResponses' => [] })))
        .to eq([400, -32_602])
    end

    it 'answers 500 with an error_id and nothing from the exception when a handler raises' do
      status, _headers, body = call('tools/call', { 'name' => 'boom' })

      expect(status).to eq(500)
      expect(body['error'].slice('code', 'message')).to eq('code' => -32_603, 'message' => 'Internal error')
      error_id = body.dig('error', 'data', 'error_id')
      expect(error_id).to match(/\A\h{16}\z/)
      expect(log.string).to include('MCP tool call failed', 'tool_failed', 'RuntimeError', error_id)
      expect(log.string + body.to_s).not_to include('hunter2')
    end

    it 'withholds a result that does not conform to the output schema' do
      status, _headers, body = call('tools/call', { 'name' => 'leaky' })

      expect(status).to eq(500)
      expect(body.dig('error', 'code')).to eq(-32_603)
      expect(log.string).to include('tool_output_invalid', '/additionalProperties')
      expect(log.string + body.to_s).not_to include('hunter2', 'password')
    end

    # "Servers MUST bind elicitation requests to the client and user identity".
    it 'does not deliver an input request when there is no verified caller to bind it to' do
      status, _headers, body = call('tools/call', { 'name' => 'asks' }, capabilities: { 'elicitation' => { 'url' => {} } })

      expect(status).to eq(500)
      expect(body.to_s).not_to include('example.com/enter')
      expect(log.string).to include('input_request_unbound')
    end

    it 'answers 400 to a requestState when there is no verified caller it could belong to' do
      expect(error_of(call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 1, 'b' => 2 }, 'requestState' => 'v1.abc' })))
        .to eq([400, -32_602])
    end

    describe 'the Mcp-Name header' do
      it 'is required' do
        response = call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 1, 'b' => 2 } }, headers: { 'HTTP_MCP_NAME' => nil })

        expect(error_of(response)).to eq([400, -32_020])
      end

      it 'must equal the tool name in the body' do
        response = call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 1, 'b' => 2 } }, headers: { 'HTTP_MCP_NAME' => 'echo' })

        expect(error_of(response)).to eq([400, -32_020])
      end

      it 'is decoded when it arrives in the Base64 form' do
        encoded  = "=?base64?#{['add'].pack('m0')}?="
        response = call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 1, 'b' => 2 } }, headers: { 'HTTP_MCP_NAME' => encoded })

        expect(response[0]).to eq(200)
      end

      it 'is refused in a Base64 spelling other than the canonical one' do
        # 'add' is YWRk. Unpadded 'ad' (YWQ) plus stray bits is not canonical.
        ['=?base64?YWRk=?=', '=?base64?YWR?=', '=?base64?YWRl?='].each do |encoded|
          response = call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 1, 'b' => 2 } }, headers: { 'HTTP_MCP_NAME' => encoded })

          expect(error_of(response)).to eq([400, -32_020])
        end
      end

      it 'is refused, not an error, when it has bytes that are invalid in its encoding' do
        [(+"add\xFF").force_encoding(Encoding::UTF_8), "add\xFF".b].each do |odd|
          response = call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 1, 'b' => 2 } }, headers: { 'HTTP_MCP_NAME' => odd })

          expect(error_of(response)).to eq([400, -32_020])
        end
      end

      it 'matches a name that is not ASCII when it arrives encoded' do
        otto.mcp_server.protocol.registry.register_tool("caf\u00E9", 'Cafe', { type: 'object' }, ->(_a, _e) { 'ok' })
        encoded = "=?base64?#{["caf\u00E9"].pack('m0')}?="

        expect(call('tools/call', { 'name' => "caf\u00E9" }, headers: { 'HTTP_MCP_NAME' => encoded })[0]).to eq(200)
      end

      it 'is refused when its Base64 form decodes to another name' do
        encoded  = "=?base64?#{['echo'].pack('m0')}?="
        response = call('tools/call', { 'name' => 'add', 'arguments' => { 'a' => 1, 'b' => 2 } }, headers: { 'HTTP_MCP_NAME' => encoded })

        expect(error_of(response)).to eq([400, -32_020])
      end
    end

    it 'gives the handler the declared capabilities and client info, and no caller' do
      seen = nil
      otto.register_mcp_tool('inspect', description: 'Inspect.', input_schema: { type: 'object' }) do |_arguments, env|
        seen = env['otto.mcp.call']
        'ok'
      end

      call('tools/call', { 'name' => 'inspect' }, capabilities: { 'elicitation' => { 'url' => {} } },
        meta: { 'io.modelcontextprotocol/clientInfo' => { 'name' => 'ExampleClient', 'version' => '1.0.0' } })

      expect(seen).to have_attributes(auth: nil, protocol_version: '2026-07-28', state: nil, input_responses: {},
        client_info: { 'name' => 'ExampleClient', 'version' => '1.0.0' })
      expect(seen).to be_url_elicitation
      expect(seen).not_to be_retry
    end
  end

  describe 'resources/read' do
    before do
      otto.register_mcp_resource('docs/a', -> { 'contents of a' }, description: 'A')
      otto.register_mcp_resource('docs/boom', -> { raise 'path /srv/secret' }, description: 'Raises')
    end

    it 'returns the contents, marked as not to be shared or kept' do
      status, _headers, body = call('resources/read', { 'uri' => 'docs/a' })

      expect(status).to eq(200)
      expect(body['result']).to include(
        'contents' => [{ 'uri' => 'docs/a', 'mimeType' => 'text/plain', 'text' => 'contents of a' }],
        'ttlMs' => 0, 'cacheScope' => 'private'
      )
    end

    # "If the requested resource does not exist, servers MUST return a
    # JSON-RPC error with code -32602 (Invalid Params)."
    it 'answers 400 Invalid params to an unknown URI' do
      status, _headers, body = call('resources/read', { 'uri' => 'docs/missing' })

      expect(status).to eq(400)
      expect(body['error']).to eq('code' => -32_602, 'message' => 'Resource not found', 'data' => { 'uri' => 'docs/missing' })
    end

    it 'answers 500 without the exception message when the handler raises' do
      status, _headers, body = call('resources/read', { 'uri' => 'docs/boom' })

      expect(status).to eq(500)
      expect(log.string).to include('MCP resource read failed', 'resource_failed', body.dig('error', 'data', 'error_id'))
      expect(log.string + body.to_s).not_to include('/srv/secret')
    end

    it 'requires the Mcp-Name header to equal the URI' do
      expect(error_of(call('resources/read', { 'uri' => 'docs/a' }, headers: { 'HTTP_MCP_NAME' => 'docs/b' }))).to eq([400, -32_020])
    end
  end

  describe 'GET and DELETE' do
    # "HTTP GET or DELETE to the MCP endpoint: respond with 405 Method Not Allowed."
    %w[GET DELETE].each do |verb|
      it "answers 405 to #{verb}" do
        status, headers, = otto.call(Rack::MockRequest.env_for('/mcp', method: verb))

        expect(status).to eq(405)
        expect(headers['allow']).to eq('POST')
      end
    end
  end

  describe 'the Origin header' do
    # "If the Origin header is present and invalid, servers MUST respond
    # with HTTP 403 Forbidden."
    it 'is refused by default, before the request is read' do
      status, = call('server/discover', {}, headers: { 'HTTP_ORIGIN' => 'https://app.example.com' })

      expect(status).to eq(403)
    end

    it 'does not affect a request that has none' do
      expect(call('server/discover')[0]).to eq(200)
    end

    context 'with allowed_origins' do
      let(:options) { { allowed_origins: ['https://app.example.com'] } }

      it 'admits a listed origin and refuses any other' do
        expect(call('server/discover', {}, headers: { 'HTTP_ORIGIN' => 'https://app.example.com' })[0]).to eq(200)
        expect(call('server/discover', {}, headers: { 'HTTP_ORIGIN' => 'https://evil.example' })[0]).to eq(403)
      end
    end
  end
end
