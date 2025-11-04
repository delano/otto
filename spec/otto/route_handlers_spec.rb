# spec/otto/route_handlers_spec.rb

require_relative '../spec_helper'

# Authentication result data class to replace OpenStruct
AuthResultData = Data.define(:session, :user) do
  def initialize(session: {}, user: {})
    super(session: session, user: user)
  end

  # Provide user_context method for compatibility with existing AuthResult
  def user_context
    { session: session, user: user }
  end
end

RSpec.describe Otto::RouteHandlers do
  let(:route_definition) do
    Otto::RouteDefinition.new('GET', '/test', 'TestApp.index')
  end

  describe Otto::RouteHandlers::HandlerFactory do
    describe '.create_handler' do
      it 'creates LogicClassHandler for logic routes' do
        logic_definition = Otto::RouteDefinition.new('GET', '/logic', 'SomeLogic')
        handler = described_class.create_handler(logic_definition)

        expect(handler).to be_a(Otto::RouteHandlers::LogicClassHandler)
      end

      it 'creates InstanceMethodHandler for instance routes' do
        instance_definition = Otto::RouteDefinition.new('GET', '/instance', 'TestApp#index')
        handler = described_class.create_handler(instance_definition)

        expect(handler).to be_a(Otto::RouteHandlers::InstanceMethodHandler)
      end

      it 'creates ClassMethodHandler for class routes' do
        class_definition = Otto::RouteDefinition.new('GET', '/class', 'TestApp.index')
        handler = described_class.create_handler(class_definition)

        expect(handler).to be_a(Otto::RouteHandlers::ClassMethodHandler)
      end

      it 'raises error for unknown handler kind' do
        # Create a custom route definition class with unknown kind for testing
        test_route_definition = Class.new do
          def initialize
            @verb = :GET
            @path = '/test'
            @definition = 'TestApp.index'
            @kind = :unknown
          end

          attr_reader :verb, :path, :definition, :kind
        end

        unknown_definition = test_route_definition.new

        expect do
          described_class.create_handler(unknown_definition)
        end.to raise_error(ArgumentError, /Unknown handler kind: unknown/)
      end
    end
  end

  describe Otto::RouteHandlers::BaseHandler do
    let(:handler) { described_class.new(route_definition) }

    describe '#call' do
      it 'raises NotImplementedError' do
        env = {}

        expect do
          handler.call(env)
        end.to raise_error(NotImplementedError, /Subclasses must implement #call/)
      end
    end
  end

  describe Otto::RouteHandlers::LogicClassHandler do
    # Create a mock Logic class for testing
    class TestLogic
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        @context = context
        @params = params
        @locale = locale
      end

      def raise_concerns
        # Mock method
      end

      def process
        { result: 'logic_processed', params: @params }
      end

      def response_data
        { logic_result: process }
      end
    end

    let(:logic_definition) do
      Otto::RouteDefinition.new('GET', '/logic', 'TestLogic auth=authenticated response=json')
    end

    let(:handler) { Otto::RouteHandlers::LogicClassHandler.new(logic_definition) }
    let(:env) do
      {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/logic',
        'QUERY_STRING' => '',
        'rack.input' => StringIO.new,
        'otto.auth_result' => AuthResultData.new(session: { user_id: 123 }, user: { name: 'Test User' }),
      }
    end

    before do
      stub_const('TestLogic', TestLogic)
    end

    describe '#call' do
      it 'processes logic class correctly' do
        status, headers, body = handler.call(env, { extra: 'param' })

        expect(status).to eq(200)
        expect(headers['Content-Type']).to eq('application/json')

        # Parse JSON body
        response_data = JSON.parse(body.first)
        expect(response_data['logic_result']['result']).to eq('logic_processed')
        expect(response_data['logic_result']['params']['extra']).to eq('param')
      end

      it 'handles errors gracefully' do
        # Make the logic class raise an error
        allow_any_instance_of(TestLogic).to receive(:process).and_raise(StandardError, 'Test error')

        status, _, body = handler.call(env)

        expect(status).to eq(500)
        expect(body.first).to include('An error occurred. Please try again later.')
      end

      it 'shows debug details when in development mode' do
        allow(Otto).to receive(:env?).with(:dev, :development).and_return(true)
        allow_any_instance_of(TestLogic).to receive(:process).and_raise(StandardError, 'Test error')

        status, _, body = handler.call(env)

        expect(status).to eq(500)
        expect(body.first).to include('Server error (ID:')
      end
    end
  end

  describe Otto::RouteHandlers::InstanceMethodHandler do
    # Create a mock controller class for testing
    class TestController
      attr_reader :request, :response

      def initialize(request, response)
        @request = request
        @response = response
      end

      def index
        @response.write('Instance method called')
        { controller: 'instance', method: 'index' }
      end
    end

    let(:instance_definition) do
      Otto::RouteDefinition.new('GET', '/instance', 'TestController#index')
    end

    let(:handler) { Otto::RouteHandlers::InstanceMethodHandler.new(instance_definition) }
    let(:env) do
      {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/instance',
        'QUERY_STRING' => '',
        'rack.input' => StringIO.new,
      }
    end

    before do
      stub_const('TestController', TestController)
    end

    describe '#call' do
      it 'calls instance method correctly' do
        status, _, body = handler.call(env)

        expect(status).to eq(200)
        expect(body).to include('Instance method called')
      end

      it 'handles errors gracefully' do
        allow_any_instance_of(TestController).to receive(:index).and_raise(StandardError, 'Controller error')

        status, _, body = handler.call(env)

        expect(status).to eq(500)
        expect(body.first).to include('An error occurred. Please try again later.')
      end
    end
  end

  describe Otto::RouteHandlers::ClassMethodHandler do
    # Create a mock controller class for testing
    class TestClassController
      def self.index(_request, response)
        response.write('Class method called')
        { controller: 'class', method: 'index' }
      end
    end

    let(:class_definition) do
      Otto::RouteDefinition.new('GET', '/class', 'TestClassController.index')
    end

    let(:handler) { Otto::RouteHandlers::ClassMethodHandler.new(class_definition) }
    let(:env) do
      {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/class',
        'QUERY_STRING' => '',
        'rack.input' => StringIO.new,
      }
    end

    before do
      stub_const('TestClassController', TestClassController)
    end

    describe '#call' do
      it 'calls class method correctly' do
        status, _, body = handler.call(env)

        expect(status).to eq(200)
        expect(body).to include('Class method called')
      end

      it 'handles errors gracefully' do
        allow(TestClassController).to receive(:index).and_raise(StandardError, 'Class method error')

        status, _, body = handler.call(env)

        expect(status).to eq(500)
        expect(body.first).to include('Server error')
        expect(body.first).to include('Check logs for details')
      end
    end
  end

  describe 'Integration with Otto::Route' do
    # Create test classes with unique names to avoid conflicts
    class RouteHandlerTestApp
      def self.index(_request, response)
        response.write('Hello from TestApp')
        'success'
      end
    end

    class RouteHandlerTestInstanceApp
      def initialize(request, response)
        @request = request
        @response = response
      end

      def show
        @response.write('Instance method response')
        'instance_success'
      end
    end

    before do
      stub_const('RouteHandlerTestApp', RouteHandlerTestApp)
      stub_const('RouteHandlerTestInstanceApp', RouteHandlerTestInstanceApp)
    end

    it 'uses route handler factory when configured' do
      otto = Otto.new
      route = Otto::Route.new('GET', '/test', 'RouteHandlerTestApp.index')
      route.otto = otto

      env = {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/test',
        'QUERY_STRING' => '',
        'rack.input' => StringIO.new,
      }

      status, _, body = route.call(env)

      expect(status).to eq(200)
      expect(body).to include('Hello from TestApp')
    end

    it 'works with custom route handler factory' do
      # Create a custom factory for testing
      custom_factory = Class.new do
        def self.create_handler(route_definition, otto_instance = nil)
          # Always return a simple test handler
          Class.new(Otto::RouteHandlers::BaseHandler) do
            def call(_env, _extra_params = {})
              res = Rack::Response.new
              res.write('Custom handler response')
              res.finish
            end
          end.new(route_definition, otto_instance)
        end
      end

      otto = Otto.new(nil, route_handler_factory: custom_factory)
      route = Otto::Route.new('GET', '/custom', 'RouteHandlerTestApp.index')
      route.otto = otto

      env = {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/custom',
        'QUERY_STRING' => '',
        'rack.input' => StringIO.new,
      }

      status, _, body = route.call(env)

      expect(status).to eq(200)
      expect(body).to include('Custom handler response')
    end
  end
end
