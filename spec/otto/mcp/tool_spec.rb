# spec/otto/mcp/tool_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::Tool do
  let(:input_schema) do
    { type: 'object', properties: { operation_id: { type: 'string', maxLength: 64 } }, required: ['operation_id'] }
  end
  let(:output_schema) do
    { type: 'object', properties: { state: { enum: %w[queued revealed] } }, required: ['state'], additionalProperties: false }
  end
  let(:definition) do
    { name: 'get_delivery_status', handler: ->(_arguments, _env) { { state: 'queued' } },
      description: 'Report where a handoff stands.', input_schema: input_schema }
  end

  def tool(**overrides)
    described_class.new(**definition, **overrides)
  end

  describe 'a declared tool' do
    it 'is frozen, with frozen String-keyed schemas' do
      built = tool(output_schema: output_schema, scopes: %w[handoff:read])

      expect(built).to be_frozen
      expect(built.input_schema).to be_frozen
      expect(built.input_schema['properties']).to be_frozen
      expect(built.input_schema.dig('properties', 'operation_id', 'type')).to eq('string')
      expect(built.scopes).to eq(%w[handoff:read]).and be_frozen
    end

    it 'does not share the schema it was given' do
      built = tool
      input_schema[:properties][:operation_id][:type] = 'integer'

      expect(built.input_schema.dig('properties', 'operation_id', 'type')).to eq('string')
    end

    it 'closes the root of the input schema when the schema does not say' do
      expect(tool.input_schema['additionalProperties']).to be(false)
      expect(tool.listing[:inputSchema]['additionalProperties']).to be(false)
    end

    it 'keeps an explicit additionalProperties' do
      open_schema = input_schema.merge(additionalProperties: true)

      expect(tool(input_schema: open_schema).input_schema['additionalProperties']).to be(true)
      expect(tool(input_schema: open_schema).input_violations('operation_id' => 'a', 'more' => 1)).to be_empty
    end

    it 'lists what a client needs and nothing about the handler or scopes' do
      built = tool(output_schema: output_schema, scopes: %w[handoff:read], title: 'Delivery status',
                   annotations: { readOnlyHint: true })

      expect(built.listing.keys).to eq(%i[name title description inputSchema outputSchema annotations])
      expect(built.listing[:annotations]).to eq('readOnlyHint' => true)
    end

    it 'leaves optional members out of the listing' do
      expect(tool.listing.keys).to eq(%i[name description inputSchema])
    end
  end

  describe '#input_violations' do
    it 'is empty for conforming arguments' do
      expect(tool.input_violations('operation_id' => 'op_1')).to be_empty
    end

    it 'names the location and the rule, never the value' do
      violations = tool.input_violations('operation_id' => 's3cr3t-value-' * 10, 'password' => 'hunter2')

      expect(violations).to contain_exactly(a_string_including('/operation_id'), a_string_including('/password'))
      expect(violations.join).not_to include('s3cr3t-value', 'hunter2')
    end

    it 'reports arguments that are not an object' do
      expect(tool.input_violations(['op_1'])).to eq(['value at root is not an object'])
    end

    it 'reports at most MAX_REPORTED_VIOLATIONS' do
      surplus = (1..50).to_h { |n| ["extra#{n}", n] }

      expect(tool.input_violations(surplus).size).to eq(described_class::MAX_REPORTED_VIOLATIONS)
    end
  end

  describe '#output_violations' do
    it 'is empty without an output schema' do
      expect(tool.output_violations('anything' => 1)).to be_empty
    end

    it 'gives the keyword and schema location, never the value' do
      violations = tool(output_schema: output_schema).output_violations('state' => 'queued', 'reveal_key' => 'k3y')

      expect(violations).to eq([{ keyword: 'schema', schema_pointer: '/additionalProperties' }])
      expect(violations.inspect).not_to include('k3y', 'reveal_key')
    end
  end

  describe '#permits?' do
    let(:reader) { Otto::MCP::Auth::Context.new(subject: 'cust_1', scopes: %w[handoff:read]) }

    it 'admits anyone to a tool with no scopes' do
      expect(tool.permits?(nil)).to be(true)
      expect(tool(scopes: []).permits?(nil)).to be(true)
    end

    it 'admits only a caller who has every scope' do
      expect(tool(scopes: %w[handoff:read]).permits?(reader)).to be(true)
      expect(tool(scopes: %w[handoff:read handoff:write]).permits?(reader)).to be(false)
      expect(tool(scopes: %w[handoff:read]).permits?(nil)).to be(false)
    end
  end

  describe '#invoke' do
    it 'calls a callable with the arguments and the env' do
      built = tool(handler: ->(arguments, env) { [arguments, env] })

      expect(built.invoke({ 'a' => 1 }, { 'e' => 2 })).to eq([{ 'a' => 1 }, { 'e' => 2 }])
    end

    it 'resolves a "Class.method" handler when called' do
      expect(tool(handler: 'TestMCPTool.echo').invoke({ 'message' => 'hi' }, {})).to eq('echo:hi')
      expect(tool(handler: 'TestMCP::NestedTool.ping').invoke({ 'n' => 1 }, {})).to eq('pong:1')
    end
  end

  describe 'refused definitions' do
    {
      'a name with a space' => [{ name: 'get status' }, /must match/],
      'a name with a slash' => [{ name: 'tools/get' }, /must match/],
      'a name over 128 characters' => [{ name: 'a' * 129 }, /must match/],
      'a non-String name' => [{ name: :get_status }, /must match/],
      'a blank description' => [{ description: '  ' }, /description must be a non-blank String/],
      'no handler' => [{ handler: nil }, /handler must respond to #call/],
      'a handler that names no method' => [{ handler: 'JustAClass' }, /handler must respond to #call/],
      'an input schema that is not a Hash' => [{ input_schema: 'object' }, /input_schema must be a Hash/],
      'an input schema whose root is not an object' => [{ input_schema: { type: 'array' } }, /type "object" at its root/],
      'an input schema that is not valid JSON Schema' => [{ input_schema: { type: 'object', properties: 5 } },
                                                          /not a valid JSON Schema/],
      'an input schema in an unknown dialect' => [{ input_schema: { '$schema' => 'https://example.com/dialect', type: 'object' } },
                                                  /cannot be used: UnknownRef/],
      'an output schema that is not valid JSON Schema' => [{ output_schema: { type: 'no-such-type' } },
                                                           /output_schema is not a valid JSON Schema/],
      'a $ref to a network address' => [
        { input_schema: { type: 'object', properties: { a: { '$ref' => 'https://example.com/schema.json' } } } },
        /\$ref to a network address/,
      ],
      'an x-mcp-header annotation' => [
        { input_schema: { type: 'object', properties: { region: { type: 'string', 'x-mcp-header' => 'Region' } } } },
        /x-mcp-header, which Otto does not support/,
      ],
      'a scope with a space' => [{ scopes: ['handoff read'] }, /scopes must be OAuth scope tokens/],
      'a scope with a quote' => [{ scopes: ['hand"off'] }, /scopes must be OAuth scope tokens/],
      'a non-String scope' => [{ scopes: [:admin] }, /scopes must be OAuth scope tokens/],
    }.each do |label, (overrides, message)|
      it "refuses #{label}" do
        expect { tool(**overrides) }.to raise_error(ArgumentError, message)
      end
    end

    it 'accepts a local $ref' do
      schema = { type: 'object', properties: { id: { '$ref' => '#/$defs/id' } }, '$defs' => { id: { type: 'string' } } }

      expect(tool(input_schema: schema).input_violations('id' => 7)).to eq(['value at `/id` is not a string'])
    end

    it 'accepts a draft-07 schema' do
      schema = { '$schema' => 'http://json-schema.org/draft-07/schema#', type: 'object' }

      expect(tool(input_schema: schema).input_violations({})).to be_empty
    end
  end

  describe '.undeclared' do
    subject(:legacy) { described_class.undeclared('anything goes/here', 'Tool: x', schema, 'TestMCPTool.echo') }

    let(:schema) { { type: 'object', properties: {}, required: [] } }

    it 'keeps exactly what it was given' do
      expect(legacy.listing).to eq(name: 'anything goes/here', description: 'Tool: x', inputSchema: schema)
      expect(legacy.listing[:inputSchema]).to be(schema)
    end

    it 'is not declared, has no scopes and admits anyone' do
      expect(legacy).not_to be_declared
      expect(legacy.scopes).to be_empty
      expect(legacy.permits?(nil)).to be(true)
    end

    it 'does not need json_schemer' do
      allow(Otto::MCP::Validator).to receive(:ensure_available!).and_raise(Otto::OptionalDependencyError, 'missing')

      expect { described_class.undeclared('t', 'd', schema, 'TestMCPTool.echo') }.not_to raise_error
      expect { tool }.to raise_error(Otto::OptionalDependencyError)
    end
  end
end
