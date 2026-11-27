# spec/otto/mcp/registration_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::Registration do
  include_context 'with rack attack isolation'

  let(:otto) do
    create_minimal_otto.tap { |app| app.enable_mcp!(allow_unauthenticated: true, enable_rate_limiting: false) }
  end
  let(:registry)   { otto.mcp_server.protocol.registry }
  let(:definition) { { description: 'Echo the message.', input_schema: { type: 'object', properties: { message: { type: 'string' } } } } }

  describe '#register_mcp_tool' do
    it 'registers a declared tool from a block' do
      tool = otto.register_mcp_tool('echo', **definition) { |arguments, _env| arguments['message'] }

      expect(tool).to be_a(Otto::MCP::Tool).and be_declared
      expect(registry.call_tool('echo', { 'message' => 'hi' }, {})).to eq(content: [{ type: 'text', text: 'hi' }])
    end

    it 'registers a declared tool from a callable or a "Class.method" String' do
      otto.register_mcp_tool('from_lambda', ->(arguments, _env) { arguments['message'] }, **definition)
      otto.register_mcp_tool('from_string', 'TestMCPTool.echo', **definition)

      expect(registry.call_tool('from_lambda', { 'message' => 'a' }, {})[:content].first[:text]).to eq('a')
      expect(registry.call_tool('from_string', { 'message' => 'b' }, {})[:content].first[:text]).to eq('echo:b')
    end

    it 'does not require an output schema or scopes on an endpoint that is not hosted' do
      expect { otto.register_mcp_tool('echo', ->(_a, _e) {}, **definition) }.not_to raise_error
    end

    it 'refuses a name that is taken, by a declared tool or by a route line' do
      otto.register_mcp_tool('echo', ->(_a, _e) {}, **definition)
      registry.register_tool('legacy', 'Legacy', {}, 'TestMCPTool.echo')

      expect { otto.register_mcp_tool('echo', ->(_a, _e) {}, **definition) }.to raise_error(ArgumentError, /already registered/)
      expect { otto.register_mcp_tool('legacy', ->(_a, _e) {}, **definition) }.to raise_error(ArgumentError, /already registered/)
    end

    it 'refuses an unknown definition keyword' do
      expect { otto.register_mcp_tool('echo', ->(_a, _e) {}, **definition, scope: 'typo') }.to raise_error(ArgumentError, /scope/)
    end

    it 'refuses a missing description or input schema' do
      expect { otto.register_mcp_tool('echo', ->(_a, _e) {}, input_schema: { type: 'object' }) }.to raise_error(ArgumentError, /description/)
      expect { otto.register_mcp_tool('echo', ->(_a, _e) {}, description: 'Echo.') }.to raise_error(ArgumentError, /input_schema/)
    end

    it 'raises when MCP is not enabled' do
      expect { create_minimal_otto.register_mcp_tool('echo', ->(_a, _e) {}, **definition) }
        .to raise_error(ArgumentError, /MCP is not enabled\. Call enable_mcp!/)
    end

    it 'raises when the MCP server exists but its HTTP endpoint was not enabled' do
      app = Otto.new(nil, mcp_stdio: true, mcp_http: false)

      expect { app.register_mcp_tool('echo', ->(_a, _e) {}, **definition) }.to raise_error(ArgumentError, /MCP is not enabled/)
    end

    it 'raises FrozenError once the configuration is frozen' do
      otto.freeze_configuration!

      expect { otto.register_mcp_tool('echo', ->(_a, _e) {}, **definition) }.to raise_error(FrozenError)
    end
  end

  describe '#register_mcp_resource' do
    it 'registers a resource whose handler takes nothing or the env' do
      otto.register_mcp_resource('docs/plain', -> { 'plain' }, description: 'Plain')
      otto.register_mcp_resource('docs/env', description: 'Env', name: 'With env', mime_type: 'text/markdown') { |env| env['PATH_INFO'] }

      expect(registry.list_resources).to eq([
                                              { uri: 'docs/plain', name: 'plain', description: 'Plain', mimeType: 'text/plain' },
                                              { uri: 'docs/env', name: 'With env', description: 'Env', mimeType: 'text/markdown' },
                                            ])
      expect(registry.read_resource('docs/env', { 'PATH_INFO' => '/_mcp' }).dig(:contents, 0, :text)).to eq('/_mcp')
    end

    it 'refuses a missing handler, an unknown keyword, or scopes with no authenticator' do
      expect { otto.register_mcp_resource('docs/a', description: 'A') }.to raise_error(ArgumentError, /handler must respond to #call/)
      expect { otto.register_mcp_resource('docs/a', -> { 'a' }, description: 'A', scope: 'x') }
        .to raise_error(ArgumentError, 'Unknown MCP resource option(s): :scope')
      expect { otto.register_mcp_resource('docs/a', -> { 'a' }, description: 'A', scopes: %w[read]) }
        .to raise_error(ArgumentError, /no authenticator/)
    end

    it 'raises when MCP is not enabled, and FrozenError once the configuration is frozen' do
      expect { create_minimal_otto.register_mcp_resource('docs/a', -> { 'a' }, description: 'A') }
        .to raise_error(ArgumentError, /MCP is not enabled/)

      otto.freeze_configuration!
      expect { otto.register_mcp_resource('docs/a', -> { 'a' }, description: 'A') }.to raise_error(FrozenError)
    end
  end

  describe 'route lines beside declared tools' do
    it 'still load on an endpoint that is not hosted' do
      routes = create_test_routes_file('mixed_mcp_routes.txt', ['POST /mcp/echo TOOL echo TestMCPTool.echo'])
      otto.register_mcp_tool('declared', ->(_a, _e) { 'd' }, **definition)

      otto.load(routes)

      expect(registry.list_tools.map { |tool| tool[:name] }).to eq(%w[declared echo])
    end
  end
end
