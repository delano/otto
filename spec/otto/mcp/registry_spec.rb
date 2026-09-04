# spec/otto/mcp/registry_spec.rb
#
# frozen_string_literal: true

require_relative '../../spec_helper'

RSpec.describe Otto::MCP::Registry, 'tool and resource dispatch' do
  subject(:registry) { described_class.new }

  let(:env) { mock_rack_env(method: 'POST', path: '/_mcp') }
  let(:schema) { { type: 'object', properties: {}, required: [] } }

  describe '#call_tool' do
    context 'with a callable handler' do
      it 'passes arguments and env through and wraps the result' do
        received = nil
        handler  = lambda { |arguments, request_env|
          received = [arguments, request_env]
          'ok'
        }
        registry.register_tool('callable', 'Callable', schema, handler)

        result = registry.call_tool('callable', { 'a' => 1 }, env)

        expect(received).to eq([{ 'a' => 1 }, env])
        expect(result).to eq(content: [{ type: 'text', text: 'ok' }])
      end
    end

    context 'with a string handler' do
      it 'resolves "Klass.method" and forwards arguments and env' do
        registry.register_tool('echo', 'Echo', schema, 'TestMCPTool.echo')

        result = registry.call_tool('echo', { 'message' => 'hi' }, env)

        expect(TestMCPTool.last_arguments).to eq('message' => 'hi')
        expect(TestMCPTool.last_env).to be(env)
        expect(result).to eq(content: [{ type: 'text', text: 'echo:hi' }])
      end

      it 'resolves a namespaced "A::B.method" handler' do
        registry.register_tool('ping', 'Ping', schema, 'TestMCP::NestedTool.ping')

        result = registry.call_tool('ping', { 'n' => 3 }, env)

        expect(result).to eq(content: [{ type: 'text', text: 'pong:3' }])
      end

      it 'raises ArgumentError when the class does not exist' do
        registry.register_tool('missing', 'Missing', schema, 'NoSuchMCPClass.run')

        expect { registry.call_tool('missing', {}, env) }
          .to raise_error(ArgumentError, /Class not found/)
      end

      it 'raises NoMethodError when the method does not exist' do
        registry.register_tool('nomethod', 'No method', schema, 'TestMCPTool.not_here')

        expect { registry.call_tool('nomethod', {}, env) }.to raise_error(NoMethodError)
      end
    end

    context 'with an invalid handler' do
      it 'rejects a string without a dot separator' do
        registry.register_tool('bare', 'Bare', schema, 'TestMCPTool')

        expect { registry.call_tool('bare', {}, env) }
          .to raise_error(RuntimeError, /\AInvalid tool handler/)
      end

      it 'rejects a non-callable, non-string handler' do
        registry.register_tool('numeric', 'Numeric', schema, 42)

        expect { registry.call_tool('numeric', {}, env) }
          .to raise_error(RuntimeError, /\AInvalid tool handler/)
      end
    end

    context 'with a forbidden constant' do
      %w[Kernel File].each do |forbidden|
        it "rejects #{forbidden}" do
          registry.register_tool('bad', 'Bad', schema, "#{forbidden}.read")

          expect { registry.call_tool('bad', {}, env) }
            .to raise_error(ArgumentError, "Forbidden class name: #{forbidden}")
        end
      end

      it 'rejects a forbidden constant reached through a namespace' do
        registry.register_tool('bad_ns', 'Bad', schema, 'Object::File.read')

        expect { registry.call_tool('bad_ns', {}, env) }.to raise_error(ArgumentError)
      end
    end

    it 'raises ToolNotFoundError for an unregistered tool' do
      expect { registry.call_tool('nope', {}, env) }
        .to raise_error(Otto::MCP::ToolNotFoundError, 'Tool not found: nope')
    end
  end

  describe '#list_tools' do
    it 'exposes name, description and inputSchema without the handler' do
      registry.register_tool('echo', 'Echo tool', schema, 'TestMCPTool.echo')

      expect(registry.list_tools).to eq(
        [{ name: 'echo', description: 'Echo tool', inputSchema: schema }]
      )
    end
  end

  describe '#list_resources' do
    it 'exposes uri, name, description and mimeType without the handler' do
      registry.register_resource('docs/a', 'a', 'Resource a', 'text/plain', -> { 'x' })

      expect(registry.list_resources).to eq(
        [{ uri: 'docs/a', name: 'a', description: 'Resource a', mimeType: 'text/plain' }]
      )
    end
  end

  describe '#read_resource' do
    it 'returns the contents envelope for a registered resource' do
      registry.register_resource('docs/a', 'a', 'Resource a', 'text/plain',
                                 -> { TestMCPResource.content })

      expect(registry.read_resource('docs/a')).to eq(
        contents: [{ uri: 'docs/a', mimeType: 'text/plain', text: 'resource contents' }]
      )
    end

    it 'returns nil for an unknown uri' do
      expect(registry.read_resource('docs/missing')).to be_nil
    end

    it 'propagates handler errors instead of swallowing them' do
      registry.register_resource('docs/boom', 'boom', 'Boom', 'text/plain',
                                 -> { TestMCPResource.boom })

      expect { registry.read_resource('docs/boom') }
        .to raise_error(RuntimeError, 'resource exploded')
    end
  end
end
