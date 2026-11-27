# spec/otto/mcp/registry_enforcement_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# What the registry checks on every call, whichever protocol revision the
# request arrived under: who is calling, what is passed in, what comes back.
RSpec.describe Otto::MCP::Registry do
  subject(:registry) { described_class.new }

  let(:reader) { Otto::MCP::Auth::Context.new(subject: 'cust_1', scopes: %w[handoff:read]) }
  let(:writer) { Otto::MCP::Auth::Context.new(subject: 'cust_2', scopes: %w[handoff:read handoff:write]) }
  let(:invocations) { [] }

  def env_for(auth = nil)
    env = mock_rack_env(method: 'POST', path: '/mcp')
    env['otto.mcp.auth'] = auth if auth
    env
  end

  def declare(name, scopes: [], output_schema: nil, input_schema: nil, &handler)
    handler ||= lambda { |arguments, _env|
      invocations << arguments
      { 'state' => 'queued' }
    }
    registry.add_tool(Otto::MCP::Tool.new(
                        name: name, handler: handler, description: "#{name} tool",
                        input_schema: input_schema || { type: 'object', properties: { operation_id: { type: 'string' } } },
                        output_schema: output_schema, scopes: scopes
                      ))
  end

  describe 'who may list a tool' do
    before do
      declare('open')
      declare('read', scopes: %w[handoff:read])
      declare('write', scopes: %w[handoff:write])
      registry.register_tool('legacy', 'Legacy', { type: 'object' }, 'TestMCPTool.echo')
    end

    it 'shows an unauthenticated caller only the tools with no scopes' do
      expect(registry.list_tools.map { |tool| tool[:name] }).to eq(%w[open legacy])
    end

    it 'shows a caller the tools its scopes cover, in registration order' do
      expect(registry.list_tools(reader).map { |tool| tool[:name] }).to eq(%w[open read legacy])
      expect(registry.list_tools(writer).map { |tool| tool[:name] }).to eq(%w[open read write legacy])
    end
  end

  describe 'who may call a tool' do
    before { declare('write', scopes: %w[handoff:write]) }

    it 'runs the handler for a caller who has the scopes' do
      registry.call_tool('write', { 'operation_id' => 'op_1' }, env_for(writer))

      expect(invocations).to eq([{ 'operation_id' => 'op_1' }])
    end

    it 'refuses a caller who lacks a scope, before the handler runs' do
      expect { registry.call_tool('write', {}, env_for(reader)) }
        .to raise_error(Otto::MCP::InsufficientScopeError) { |error| expect(error.required_scopes).to eq(%w[handoff:write]) }
      expect(invocations).to be_empty
    end

    it 'refuses an unauthenticated caller' do
      expect { registry.call_tool('write', {}, env_for) }.to raise_error(Otto::MCP::InsufficientScopeError)
      expect { registry.call_tool('write', {}, nil) }.to raise_error(Otto::MCP::InsufficientScopeError)
    end

    it 'ignores a caller that is not a verified context' do
      forged = env_for
      forged['otto.mcp.auth'] = { 'scopes' => %w[handoff:write] }

      expect { registry.call_tool('write', {}, forged) }.to raise_error(Otto::MCP::InsufficientScopeError)
    end

    it 'reports an unknown tool as not found whatever scopes the caller has' do
      expect { registry.call_tool('nope', {}, env_for(reader)) }.to raise_error(Otto::MCP::ToolNotFoundError)
    end
  end

  describe 'arguments of a declared tool' do
    before { declare('status', input_schema: { type: 'object', properties: { operation_id: { type: 'string' } }, required: ['operation_id'] }) }

    it 'returns a tool error naming each violation, without running the handler' do
      result = registry.call_tool('status', { 'secret' => 'hunter2' }, env_for)

      expect(result[:isError]).to be(true)
      expect(result[:content].first[:text]).to start_with('Invalid arguments for tool status: ')
      expect(result[:content].first[:text]).to include('operation_id', '/secret')
      expect(result[:content].first[:text]).not_to include('hunter2')
      expect(invocations).to be_empty
    end

    it 'refuses arguments that are not an object' do
      expect(registry.call_tool('status', 'op_1', env_for)[:isError]).to be(true)
      expect(invocations).to be_empty
    end

    it 'passes conforming arguments to the handler' do
      registry.call_tool('status', { 'operation_id' => 'op_1' }, env_for)

      expect(invocations).to eq([{ 'operation_id' => 'op_1' }])
    end
  end

  describe 'the return value of a declared tool' do
    let(:output_schema) do
      { type: 'object', properties: { state: { type: 'string' } }, required: ['state'], additionalProperties: false }
    end

    it 'becomes structured content and its JSON text when it conforms' do
      declare('status', output_schema: output_schema) { |_arguments, _env| { state: 'queued' } }

      expect(registry.call_tool('status', {}, env_for)).to eq(
        content: [{ type: 'text', text: '{"state":"queued"}' }],
        structuredContent: { 'state' => 'queued' }
      )
    end

    it 'is withheld when it does not conform' do
      declare('status', output_schema: output_schema) { |_arguments, _env| { state: 'queued', reveal_key: 'k3y' } }

      expect { registry.call_tool('status', {}, env_for) }.to raise_error(Otto::MCP::OutputValidationError) { |error|
        expect(error.violations).to eq([{ keyword: 'schema', schema_pointer: '/additionalProperties' }])
        expect(error.message).not_to include('k3y')
      }
    end

    it 'is returned as text when the tool has no output schema' do
      declare('status') { |_arguments, _env| 'queued' }

      expect(registry.call_tool('status', {}, env_for)).to eq(content: [{ type: 'text', text: 'queued' }])
    end

    it 'passes an input request through unchanged' do
      request = Otto::MCP::InputRequired.url('handoff', url: 'https://example.com/h', message: 'Enter it.')
      declare('status', output_schema: output_schema) { |_arguments, _env| request }

      expect(registry.call_tool('status', {}, env_for)).to be(request)
    end
  end

  describe 'Otto::MCP::ToolError' do
    it 'becomes a tool error carrying the message, for a declared tool' do
      declare('status') { |_arguments, _env| raise Otto::MCP::ToolError, 'That handoff has expired.' }

      expect(registry.call_tool('status', {}, env_for))
        .to eq(content: [{ type: 'text', text: 'That handoff has expired.' }], isError: true)
    end

    it 'becomes a tool error for an undeclared tool too' do
      registry.register_tool('legacy', 'Legacy', {}, ->(_arguments, _env) { raise Otto::MCP::ToolError, 'Try later.' })

      expect(registry.call_tool('legacy', {}, env_for)[:isError]).to be(true)
    end

    it 'does not catch other errors' do
      declare('status') { |_arguments, _env| raise 'internal detail' }

      expect { registry.call_tool('status', {}, env_for) }.to raise_error(RuntimeError, 'internal detail')
    end
  end

  describe 'an undeclared tool' do
    it 'receives arguments unchecked, as it always has' do
      registry.register_tool('legacy', 'Legacy', { type: 'object', properties: {}, required: [] }, 'TestMCPTool.echo')

      result = registry.call_tool('legacy', { 'message' => 'hi', 'anything' => [1, 2] }, env_for)

      expect(result).to eq(content: [{ type: 'text', text: 'echo:hi' }])
      expect(TestMCPTool.last_arguments).to eq('message' => 'hi', 'anything' => [1, 2])
    end
  end

  describe 'resources with scopes' do
    before do
      registry.register_resource('docs/public', 'public', 'Public', 'text/plain', -> { 'open' })
      registry.register_resource('docs/private', 'private', 'Private', 'text/plain', -> { 'closed' }, scopes: %w[handoff:read])
    end

    it 'lists a resource only for a caller its scopes cover' do
      expect(registry.list_resources.map { |resource| resource[:uri] }).to eq(%w[docs/public])
      expect(registry.list_resources(reader).map { |resource| resource[:uri] }).to eq(%w[docs/public docs/private])
    end

    it 'does not put the scopes or the handler in the listing' do
      expect(registry.list_resources(reader).flat_map(&:keys).uniq).to eq(%i[uri name description mimeType])
    end

    it 'reads a scoped resource only for a caller who has the scopes' do
      expect(registry.read_resource('docs/private', env_for(reader)).dig(:contents, 0, :text)).to eq('closed')
      expect { registry.read_resource('docs/private', env_for) }.to raise_error(Otto::MCP::InsufficientScopeError)
      expect { registry.read_resource('docs/private') }.to raise_error(Otto::MCP::InsufficientScopeError)
    end

    it 'refuses scopes that are not scope tokens' do
      expect { registry.register_resource('x', 'x', 'X', 'text/plain', -> { '' }, scopes: ['a b']) }
        .to raise_error(ArgumentError, /scopes must be OAuth scope tokens/)
    end
  end

  describe '#add_tool' do
    it 'refuses a name that is already registered' do
      declare('status')

      expect { declare('status') }.to raise_error(ArgumentError, 'MCP tool status is already registered')
    end
  end

  # A later registration under the same name must not be able to drop the
  # scopes or schemas of an earlier one.
  describe 'replacing a guarded entry' do
    it 'refuses to replace a declared tool with an undeclared one' do
      declare('wipe', scopes: %w[handoff:write])

      expect { registry.register_tool('wipe', 'Wipe', {}, 'TestMCPTool.echo') }
        .to raise_error(ArgumentError, 'MCP tool wipe is declared and cannot be replaced')
      expect { registry.call_tool('wipe', {}, env_for(reader)) }.to raise_error(Otto::MCP::InsufficientScopeError)
    end

    it 'refuses to replace a resource that requires scopes' do
      registry.register_resource('docs/private', 'private', 'Private', 'text/plain', -> { 'closed' }, scopes: %w[handoff:read])

      expect { registry.register_resource('docs/private', 'private', 'Private', 'text/plain', -> { 'open' }) }
        .to raise_error(ArgumentError, 'MCP resource docs/private requires scopes and cannot be replaced')
      expect { registry.read_resource('docs/private', env_for) }.to raise_error(Otto::MCP::InsufficientScopeError)
    end

    it 'still lets an undeclared tool or an unscoped resource be registered again, as before' do
      2.times { registry.register_tool('legacy', 'Legacy', {}, 'TestMCPTool.echo') }
      2.times { |n| registry.register_resource('docs/a', 'a', 'A', 'text/plain', -> { n.to_s }) }

      expect(registry.read_resource('docs/a').dig(:contents, 0, :text)).to eq('1')
    end
  end

  describe '#require_declarations!' do
    it 'refuses to take effect when something is already registered' do
      registry.register_tool('legacy', 'Legacy', {}, 'TestMCPTool.echo')
      registry.register_resource('docs/a', 'a', 'A', 'text/plain', -> { 'a' })

      expect { registry.require_declarations! }
        .to raise_error(ArgumentError, %r{must be enabled before any tool or resource is registered\. Already registered: legacy, docs/a})
    end

    context 'when in effect' do
      before { registry.require_declarations! }

      it 'refuses an undeclared tool' do
        expect { registry.register_tool('legacy', 'Legacy', {}, 'TestMCPTool.echo') }
          .to raise_error(ArgumentError, /must be declared with register_mcp_tool/)
      end

      it 'refuses a declared tool with no output schema' do
        expect { declare('status') }.to raise_error(ArgumentError, /must state output_schema:/)
        expect { declare('status', output_schema: { type: 'object' }) }.not_to raise_error
      end

      it 'refuses a resource with no scopes stated' do
        expect { registry.register_resource('docs/a', 'a', 'A', 'text/plain', -> { 'a' }) }
          .to raise_error(ArgumentError, /must state scopes:/)
        expect { registry.register_resource('docs/a', 'a', 'A', 'text/plain', -> { 'a' }, scopes: []) }.not_to raise_error
      end
    end
  end

  describe 'a resource handler that returns an input request' do
    it 'fails the read without printing the state it was given' do
      request = Otto::MCP::InputRequired.url('k', url: 'https://example.com/h', message: 'Enter it.', state: { 'internal' => 'value' })
      registry.register_resource('docs/asks', 'asks', 'Asks', 'text/plain', -> { request })

      expect { registry.read_resource('docs/asks') }.to raise_error(Otto::MCP::InputRequestError) { |error|
        expect(error.message).not_to include('internal')
      }
    end
  end

  describe '#scoped?' do
    it 'is false until a tool or a resource requires a scope' do
      declare('open')
      expect(registry).not_to be_scoped

      registry.register_resource('r', 'r', 'R', 'text/plain', -> { '' }, scopes: %w[handoff:read])
      expect(registry).to be_scoped
    end

    it 'is true when a tool requires a scope' do
      declare('read', scopes: %w[handoff:read])

      expect(registry).to be_scoped
    end
  end

  describe '#deep_freeze!' do
    before do
      declare('status')
      registry.register_resource('docs/a', 'a', 'A', 'text/plain', -> { 'a' })
      registry.deep_freeze!
    end

    it 'refuses a new or replacement tool or resource' do
      expect { declare('another') }.to raise_error(FrozenError)
      expect { registry.register_tool('another', 'Another', {}, ->(_a, _e) { 'x' }) }.to raise_error(FrozenError)
      expect { registry.register_resource('docs/b', 'b', 'B', 'text/plain', -> { 'b' }) }.to raise_error(FrozenError)
    end

    it 'still lists, calls and reads' do
      expect(registry.list_tools.size).to eq(1)
      expect(registry.call_tool('status', {}, env_for)).to include(:content)
      expect(registry.read_resource('docs/a')).to include(:contents)
    end
  end
end
