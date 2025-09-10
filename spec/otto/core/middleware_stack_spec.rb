# spec/otto/core/middleware_stack_spec.rb

require 'spec_helper'

RSpec.describe Otto::Core::MiddlewareStack do
  let(:stack) { described_class.new }
  let(:test_middleware1) { Class.new }
  let(:test_middleware2) { Class.new }
  let(:test_middleware3) { Class.new }

  describe '#add' do
    it 'adds middleware to the stack' do
      stack.add(test_middleware1)
      expect(stack.middleware_list).to include(test_middleware1)
    end

    it 'does not add duplicate middleware' do
      stack.add(test_middleware1)
      stack.add(test_middleware1)
      expect(stack.middleware_list.count(test_middleware1)).to eq(1)
    end

    it 'stores middleware with arguments and options' do
      stack.add(test_middleware1, 'arg1', 'arg2', option: 'value')
      details = stack.middleware_details
      expect(details.first).to include(
        middleware: test_middleware1,
        args: %w[arg1 arg2],
        options: { option: 'value' }
      )
    end
  end

  describe '#middleware_list' do
    it 'returns empty array when no middleware added' do
      expect(stack.middleware_list).to eq([])
    end

    it 'returns middleware classes in order of addition' do
      stack.add(test_middleware1)
      stack.add(test_middleware2)
      stack.add(test_middleware3)

      expect(stack.middleware_list).to eq([test_middleware1, test_middleware2, test_middleware3])
    end

    it 'maintains order after removal' do
      stack.add(test_middleware1)
      stack.add(test_middleware2)
      stack.add(test_middleware3)
      stack.remove(test_middleware2)

      expect(stack.middleware_list).to eq([test_middleware1, test_middleware3])
    end
  end

  describe '#middleware_details' do
    it 'returns empty array when no middleware added' do
      expect(stack.middleware_details).to eq([])
    end

    it 'returns detailed information about each middleware' do
      stack.add(test_middleware1, 'arg1', option1: 'value1')
      stack.add(test_middleware2, 'arg2', 'arg3', option2: 'value2')

      details = stack.middleware_details
      expect(details.size).to eq(2)

      expect(details[0]).to include(
        middleware: test_middleware1,
        args: ['arg1'],
        options: { option1: 'value1' }
      )

      expect(details[1]).to include(
        middleware: test_middleware2,
        args: %w[arg2 arg3],
        options: { option2: 'value2' }
      )
    end

    it 'handles middleware with no arguments or options' do
      stack.add(test_middleware1)

      details = stack.middleware_details
      expect(details.first).to include(
        middleware: test_middleware1,
        args: [],
        options: {}
      )
    end
  end

  describe '#includes?' do
    it 'returns true when middleware is present' do
      stack.add(test_middleware1)
      expect(stack.includes?(test_middleware1)).to be true
    end

    it 'returns false when middleware is not present' do
      expect(stack.includes?(test_middleware1)).to be false
    end

    it 'returns false after middleware is removed' do
      stack.add(test_middleware1)
      stack.remove(test_middleware1)
      expect(stack.includes?(test_middleware1)).to be false
    end
  end

  describe '#remove' do
    it 'removes specified middleware' do
      stack.add(test_middleware1)
      stack.add(test_middleware2)
      stack.remove(test_middleware1)

      expect(stack.middleware_list).to eq([test_middleware2])
      expect(stack.includes?(test_middleware1)).to be false
    end

    it 'does nothing when middleware not present' do
      stack.add(test_middleware1)
      stack.remove(test_middleware2)

      expect(stack.middleware_list).to eq([test_middleware1])
    end
  end

  describe '#size' do
    it 'returns 0 for empty stack' do
      expect(stack.size).to eq(0)
    end

    it 'returns correct count after adding middleware' do
      stack.add(test_middleware1)
      stack.add(test_middleware2)
      expect(stack.size).to eq(2)
    end

    it 'decreases after removing middleware' do
      stack.add(test_middleware1)
      stack.add(test_middleware2)
      stack.remove(test_middleware1)
      expect(stack.size).to eq(1)
    end
  end

  describe '#empty?' do
    it 'returns true for new stack' do
      expect(stack).to be_empty
    end

    it 'returns false when middleware added' do
      stack.add(test_middleware1)
      expect(stack).not_to be_empty
    end

    it 'returns true after clearing all middleware' do
      stack.add(test_middleware1)
      stack.clear!
      expect(stack).to be_empty
    end
  end

  describe '#clear!' do
    it 'removes all middleware' do
      stack.add(test_middleware1)
      stack.add(test_middleware2)
      stack.clear!

      expect(stack).to be_empty
      expect(stack.middleware_list).to eq([])
    end
  end

  describe 'aliases' do
    it 'supports use as alias for add' do
      stack.use(test_middleware1, 'arg')
      expect(stack.middleware_list).to include(test_middleware1)
      expect(stack.middleware_details.first[:args]).to eq(['arg'])
    end

    it 'supports << as alias for add' do
      stack << test_middleware1
      expect(stack.middleware_list).to include(test_middleware1)
    end
  end

  describe '#build_app' do
    let(:base_app) { ->(_env) { [200, {}, ['base']] } }
    let(:security_config) { instance_double('Otto::Security::Config', csrf_enabled?: true) }

    # Mock middleware that tracks initialization
    let(:mock_middleware1) do
      Class.new do
        attr_reader :app, :config, :args, :options

        def initialize(app, *args, **options)
          @app = app
          @args = args
          @options = options
          # Detect if security_config was passed (should be first argument for security middleware)
          return unless args.first && args.first.respond_to?(:csrf_enabled?)

          @config = args.first
        end

        def call(env)
          @app.call(env)
        end
      end
    end

    it 'builds middleware chain in reverse order' do
      stack.add(mock_middleware1)
      app = stack.build_app(base_app, security_config)

      expect(app).to be_a(mock_middleware1)
      expect(app.app).to eq(base_app)
    end

    it 'passes security_config to security middleware' do
      # Mock Otto::Security::CSRFMiddleware for security config injection
      stub_const('Otto::Security::CSRFMiddleware', mock_middleware1)

      stack.add(Otto::Security::CSRFMiddleware)
      app = stack.build_app(base_app, security_config)

      expect(app.config).to eq(security_config)
    end

    it 'does not pass security_config to non-security middleware' do
      stack.add(mock_middleware1)
      app = stack.build_app(base_app, security_config)

      expect(app.config).to be_nil
    end

    it 'handles middleware with custom arguments' do
      stack.add(mock_middleware1, 'custom_arg', option: 'value')
      app = stack.build_app(base_app, security_config)

      expect(app.args).to eq(['custom_arg'])
      expect(app.options).to eq(option: 'value')
    end
  end
end
