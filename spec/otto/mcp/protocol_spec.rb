# spec/otto/mcp/protocol_spec.rb
#
# frozen_string_literal: true

require_relative '../../spec_helper'

RSpec.describe Otto::MCP::Protocol, 'JSON-RPC request handling' do
  subject(:protocol) { described_class.new(otto) }

  let(:otto) { create_minimal_otto }
  let(:schema) { { type: 'object', properties: {}, required: [] } }

  def json_env(payload, content_type: 'application/json', method: 'POST')
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    env  = mock_rack_env(method: method, path: '/_mcp')
    env['CONTENT_TYPE'] = content_type
    env['rack.input']   = StringIO.new(body)
    env
  end

  def call(payload, **kwargs)
    status, headers, body = protocol.handle_request(json_env(payload, **kwargs))
    [status, headers, JSON.parse(body.first)]
  end

  def rpc(method, params = nil, id: 1)
    payload = { 'jsonrpc' => '2.0', 'id' => id, 'method' => method }
    payload['params'] = params if params
    payload
  end

  describe 'transport validation' do
    it 'rejects non-POST requests with -32600/400' do
      status, _headers, body = call(rpc('initialize'), method: 'GET')

      expect(status).to eq(400)
      expect(body.dig('error', 'code')).to eq(-32_600)
    end

    it 'rejects non-JSON content types with -32600/400' do
      status, _headers, body = call(rpc('initialize'), content_type: 'text/plain')

      expect(status).to eq(400)
      expect(body.dig('error', 'code')).to eq(-32_600)
    end

    it 'rejects malformed JSON with -32700/400' do
      status, _headers, body = call('{not json')

      expect(status).to eq(400)
      expect(body.dig('error', 'code')).to eq(-32_700)
    end

    it 'responds with a JSON content type' do
      _status, headers, _body = call(rpc('initialize'))

      expect(headers['content-type']).to eq('application/json')
    end
  end

  describe 'envelope validation' do
    {
      'missing jsonrpc' => { 'id' => 1, 'method' => 'initialize' },
      'non-string method' => { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 42 },
      'missing id' => { 'jsonrpc' => '2.0', 'method' => 'initialize' },
    }.each do |label, payload|
      it "rejects #{label} with -32600/400" do
        status, _headers, body = call(payload)

        expect(status).to eq(400)
        expect(body.dig('error', 'code')).to eq(-32_600)
      end
    end

    it 'accepts an explicit null id and echoes it back' do
      _status, _headers, body = call(rpc('initialize', id: nil))

      expect(body).to include('id' => nil)
      expect(body).to have_key('result')
    end

    it 'echoes the id on error responses' do
      _status, _headers, body = call(rpc('does/not/exist', id: 'abc'))

      expect(body['id']).to eq('abc')
    end
  end

  describe 'initialize' do
    it 'returns the protocol version, capabilities and server info' do
      status, _headers, body = call(rpc('initialize'))

      expect(status).to eq(200)
      expect(body['result']).to include(
        'protocolVersion' => '2024-11-05',
        'capabilities' => { 'resources' => { 'subscribe' => false, 'listChanged' => false }, 'tools' => {} },
        'serverInfo' => { 'name' => 'Otto MCP Server', 'version' => Otto::VERSION }
      )
    end
  end

  describe 'unknown methods' do
    it 'returns -32601/400' do
      status, _headers, body = call(rpc('tools/frobnicate'))

      expect(status).to eq(400)
      expect(body.dig('error', 'code')).to eq(-32_601)
    end
  end

  describe 'listing' do
    before do
      protocol.registry.register_tool('echo', 'Echo tool', schema, 'TestMCPTool.echo')
      protocol.registry.register_resource('docs/a', 'a', 'Resource a', 'text/plain', -> { 'x' })
    end

    it 'lists registered tools' do
      _status, _headers, body = call(rpc('tools/list'))

      expect(body.dig('result', 'tools')).to eq(
        [{ 'name' => 'echo', 'description' => 'Echo tool', 'inputSchema' => JSON.parse(JSON.generate(schema)) }]
      )
    end

    it 'lists registered resources' do
      _status, _headers, body = call(rpc('resources/list'))

      expect(body.dig('result', 'resources')).to eq(
        [{ 'uri' => 'docs/a', 'name' => 'a', 'description' => 'Resource a', 'mimeType' => 'text/plain' }]
      )
    end
  end

  describe 'resources/read' do
    before do
      protocol.registry.register_resource('docs/a', 'a', 'Resource a', 'text/plain',
                                          -> { TestMCPResource.content })
      protocol.registry.register_resource('docs/boom', 'boom', 'Boom', 'text/plain',
                                          -> { TestMCPResource.boom })
    end

    it 'returns the resource contents' do
      status, _headers, body = call(rpc('resources/read', { 'uri' => 'docs/a' }))

      expect(status).to eq(200)
      expect(body.dig('result', 'contents')).to eq(
        [{ 'uri' => 'docs/a', 'mimeType' => 'text/plain', 'text' => 'resource contents' }]
      )
    end

    it 'returns -32602/400 when uri is missing' do
      status, _headers, body = call(rpc('resources/read', {}))

      expect(status).to eq(400)
      expect(body.dig('error', 'code')).to eq(-32_602)
    end

    it 'returns -32001/404 for an unknown uri' do
      status, _headers, body = call(rpc('resources/read', { 'uri' => 'docs/missing' }))

      expect(status).to eq(404)
      expect(body.dig('error', 'code')).to eq(-32_001)
    end

    it 'returns -32603/500 with a redacted message when the handler raises' do
      logged = []
      allow(Otto.logger).to receive(:error) { |msg| logged << msg }

      status, _headers, raw = protocol.handle_request(json_env(rpc('resources/read', { 'uri' => 'docs/boom' })))
      body = JSON.parse(raw.first)

      expect(status).to eq(500)
      expect(body.dig('error', 'code')).to eq(-32_603)
      expect(body.dig('error', 'data')).to eq('Resource read failed')
      expect(raw.first).not_to include('resource exploded')
      expect(logged.join).to include('resource exploded')
    end
  end

  describe 'tools/call' do
    before do
      protocol.registry.register_tool('echo', 'Echo tool', schema, 'TestMCPTool.echo')
      protocol.registry.register_tool('boom', 'Boom tool', schema, 'TestMCPTool.boom')
      protocol.registry.register_tool('forbidden', 'Forbidden', schema, 'Kernel.system')
    end

    it 'invokes the tool and returns the content envelope' do
      status, _headers, body = call(rpc('tools/call', { 'name' => 'echo', 'arguments' => { 'message' => 'hi' } }))

      expect(status).to eq(200)
      expect(body.dig('result', 'content')).to eq([{ 'type' => 'text', 'text' => 'echo:hi' }])
      expect(TestMCPTool.last_arguments).to eq('message' => 'hi')
    end

    it 'forwards an empty hash when arguments are omitted' do
      call(rpc('tools/call', { 'name' => 'echo' }))

      expect(TestMCPTool.last_arguments).to eq({})
    end

    it 'returns -32602/400 when name is missing' do
      status, _headers, body = call(rpc('tools/call', {}))

      expect(status).to eq(400)
      expect(body.dig('error', 'code')).to eq(-32_602)
    end

    it 'returns -32002/404 for an unregistered tool' do
      status, _headers, body = call(rpc('tools/call', { 'name' => 'nope' }))

      expect(status).to eq(404)
      expect(body.dig('error', 'code')).to eq(-32_002)
      expect(body.dig('error', 'data')).to eq('Tool not found: nope')
    end

    it 'returns -32603/500 with a redacted message when the tool raises' do
      logged = []
      allow(Otto.logger).to receive(:error) { |msg| logged << msg }

      status, _headers, raw = protocol.handle_request(json_env(rpc('tools/call', { 'name' => 'boom' })))
      body = JSON.parse(raw.first)

      expect(status).to eq(500)
      expect(body.dig('error', 'code')).to eq(-32_603)
      expect(body.dig('error', 'data')).to eq('Tool execution failed')
      expect(raw.first).not_to include('tool exploded')
      expect(logged.join).to include('tool exploded')
    end

    it 'returns -32603/500 for a forbidden constant handler without naming the class' do
      status, _headers, raw = protocol.handle_request(json_env(rpc('tools/call', { 'name' => 'forbidden' })))
      body = JSON.parse(raw.first)

      expect(status).to eq(500)
      expect(body.dig('error', 'code')).to eq(-32_603)
      expect(body.dig('error', 'data')).to eq('Tool execution failed')
      expect(raw.first).not_to include('Forbidden class name')
    end
  end

  describe 'error code to HTTP status mapping' do
    {
      -32_700 => 400,
      -32_600 => 400,
      -32_601 => 400,
      -32_602 => 400,
      -32_001 => 404,
      -32_002 => 404,
      -32_603 => 500,
      -32_050 => 500, # unmapped server-error range
      -1 => 400, # unknown code outside the server range
    }.each do |code, expected_status|
      it "maps #{code} to #{expected_status}" do
        status, = protocol.send(:error_response, 1, code, 'test')

        expect(status).to eq(expected_status)
      end
    end
  end

  describe 'mounted MCP endpoint' do
    include Rack::Test::Methods

    let(:app) do
      otto.enable_mcp!(enable_validation: false, enable_rate_limiting: false)
      otto.mcp_server.protocol.registry.register_tool('echo', 'Echo tool', schema, 'TestMCPTool.echo')
      otto
    end

    it 'dispatches JSON-RPC through the mounted route' do
      post '/_mcp', JSON.generate(rpc('tools/call', { 'name' => 'echo', 'arguments' => { 'message' => 'wired' } })),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body).dig('result', 'content'))
        .to eq([{ 'type' => 'text', 'text' => 'echo:wired' }])
    end

    it 'propagates the 404 status for an unknown tool' do
      post '/_mcp', JSON.generate(rpc('tools/call', { 'name' => 'nope' })),
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig('error', 'code')).to eq(-32_002)
    end
  end
end
