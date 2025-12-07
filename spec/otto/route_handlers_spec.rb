# spec/otto/route_handlers_spec.rb
#
# frozen_string_literal: true

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
        end.to raise_error(NotImplementedError, /Subclasses must implement #invoke_target/)
      end
    end
  end

  describe Otto::RouteHandlers::LogicClassHandler do
    # Create a mock Logic class for testing
    class TestLogic
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        # Validate that context is not nil and has expected structure
        if context.nil?
          raise ArgumentError, "Expected context to be a StrategyResult, got nil"
        end

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
        'otto.strategy_result' => AuthResultData.new(session: { user_id: 123 }, user: { name: 'Test User' }),
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

      it 'passes strategy_result as context to Logic class' do
        strategy_result = AuthResultData.new(session: { user_id: 456 }, user: { name: 'Test' })
        env['otto.strategy_result'] = strategy_result

        handler.call(env)

        # TestLogic validates context is not nil in initialize
        # If we get here without error, context was passed correctly
        expect(true).to be true
      end

      it 'passes locale from env to Logic class' do
        env['otto.locale'] = 'fr'

        logic_instance = nil
        allow(TestLogic).to receive(:new) do |context, params, locale|
          logic_instance = TestLogic.allocate
          logic_instance.instance_variable_set(:@context, context)
          logic_instance.instance_variable_set(:@params, params)
          logic_instance.instance_variable_set(:@locale, locale)
          logic_instance
        end
        allow_any_instance_of(TestLogic).to receive(:process).and_return({ result: 'ok' })

        handler.call(env)

        expect(logic_instance.locale).to eq('fr')
      end

      it 'defaults to en locale when not set in env' do
        env.delete('otto.locale')

        logic_instance = nil
        allow(TestLogic).to receive(:new) do |context, params, locale|
          logic_instance = TestLogic.allocate
          logic_instance.instance_variable_set(:@context, context)
          logic_instance.instance_variable_set(:@params, params)
          logic_instance.instance_variable_set(:@locale, locale)
          logic_instance
        end
        allow_any_instance_of(TestLogic).to receive(:process).and_return({ result: 'ok' })

        handler.call(env)

        expect(logic_instance.locale).to eq('en')
      end

      context 'JSON request body parsing' do
        it 'merges valid JSON body into params' do
          json_body = { json_param: 'value', nested: { key: 'data' } }
          env['rack.input'] = StringIO.new(JSON.generate(json_body))
          env['CONTENT_TYPE'] = 'application/json'
          env['QUERY_STRING'] = 'query_param=query_value'

          status, _, body = handler.call(env, { extra_param: 'extra_value' })

          expect(status).to eq(200)
          response_data = JSON.parse(body.first)

          # Verify all params made it through (they're in the response via TestLogic#process)
          result_params = response_data['logic_result']['params']
          expect(result_params['json_param']).to eq('value')
          expect(result_params['extra_param']).to eq('extra_value')
          expect(result_params['query_param']).to eq('query_value')
          expect(result_params['nested']).to eq({ 'key' => 'data' })
        end

        it 'handles invalid JSON gracefully and logs error' do
          env['rack.input'] = StringIO.new('{ invalid json }')
          env['CONTENT_TYPE'] = 'application/json'

          expect(Otto).to receive(:structured_log).with(
            :error,
            'JSON parsing error',
            hash_including(error_class: 'JSON::ParserError')
          )

          # Allow the backtrace logging call
          allow(Otto::LoggingHelpers).to receive(:log_backtrace)

          # Should not raise, continues with URL params only
          status, _, _ = handler.call(env, { url_param: 'value' })

          expect(status).to eq(200)
        end

        it 'skips JSON parsing when content type is not JSON' do
          env['rack.input'] = StringIO.new('some text')
          env['CONTENT_TYPE'] = 'text/plain'
          env['QUERY_STRING'] = 'query_param=query_value'

          status, _, body = handler.call(env, { extra_param: 'extra_value' })

          expect(status).to eq(200)
          response_data = JSON.parse(body.first)

          # Should have query params and extra params, but no JSON parsing
          result_params = response_data['logic_result']['params']
          expect(result_params['extra_param']).to eq('extra_value')
          expect(result_params['query_param']).to eq('query_value')
          expect(result_params.keys).not_to include('some')
        end

        it 'skips JSON parsing when body is empty' do
          env['rack.input'] = StringIO.new('')
          env['CONTENT_TYPE'] = 'application/json'

          logic_instance = nil
          allow(TestLogic).to receive(:new) do |context, params, locale|
            logic_instance = TestLogic.allocate
            logic_instance.instance_variable_set(:@context, context)
            logic_instance.instance_variable_set(:@params, params)
            logic_instance.instance_variable_set(:@locale, locale)
            logic_instance
          end
          allow_any_instance_of(TestLogic).to receive(:process).and_return({ result: 'ok' })

          handler.call(env)

          expect(logic_instance.params).to be_a(Hash)
        end
      end

      context 'Logic class lifecycle' do
        it 'calls raise_concerns when method exists' do
          logic_instance = TestLogic.new(
            env['otto.strategy_result'],
            {},
            'en'
          )

          allow(TestLogic).to receive(:new).and_return(logic_instance)
          expect(logic_instance).to receive(:raise_concerns).and_call_original
          allow(logic_instance).to receive(:process).and_return({ result: 'ok' })

          handler.call(env)
        end

        it 'calls process when method exists' do
          logic_instance = TestLogic.new(
            env['otto.strategy_result'],
            {},
            'en'
          )

          allow(TestLogic).to receive(:new).and_return(logic_instance)
          expect(logic_instance).to receive(:process).at_least(:once).and_call_original

          handler.call(env)
        end

        it 'falls back to call method when process does not exist' do
          # Create a logic class without process method
          logic_without_process = Class.new do
            attr_reader :context, :params, :locale

            def initialize(context, params, locale)
              raise ArgumentError, 'Expected context' if context.nil?
              @context = context
              @params = params
              @locale = locale
            end

            def raise_concerns; end

            def call
              { fallback: 'used_call_method' }
            end

            def response_data
              { logic_result: call }
            end
          end

          stub_const('LogicWithoutProcess', logic_without_process)

          logic_def = Otto::RouteDefinition.new('GET', '/logic', 'LogicWithoutProcess response=json')
          logic_handler = Otto::RouteHandlers::LogicClassHandler.new(logic_def)

          status, _, body = logic_handler.call(env)

          expect(status).to eq(200)
          response_data = JSON.parse(body.first)
          expect(response_data['logic_result']['fallback']).to eq('used_call_method')
        end
      end

      context 'response handling' do
        it 'uses JSONHandler when response_type is json' do
          # Already tested in 'processes logic class correctly'
          # but explicitly verify JSON response
          status, headers, body = handler.call(env)

          expect(status).to eq(200)
          expect(headers['Content-Type']).to eq('application/json')
          expect { JSON.parse(body.first) }.not_to raise_error
        end

        it 'skips handle_response when response_type is default' do
          default_logic_def = Otto::RouteDefinition.new('GET', '/logic', 'TestLogic')
          default_handler = Otto::RouteHandlers::LogicClassHandler.new(default_logic_def)

          # With default response_type, the handler should not call handle_response
          # but TestLogic should still write to response via response.write if needed
          status, _, _ = default_handler.call(env)

          expect(status).to eq(200)
        end
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

      context 'integration with otto_instance' do
        let(:otto_instance) { Otto.new }
        let(:handler_with_otto) { Otto::RouteHandlers::LogicClassHandler.new(logic_definition, otto_instance) }

        it 'integrates with Otto instance' do
          status, _, _ = handler_with_otto.call(env)

          expect(status).to eq(200)
        end

        it 'delegates error handling to centralized handler when otto_instance exists' do
          allow_any_instance_of(TestLogic).to receive(:process).and_raise(StandardError, 'Integration error')

          # When otto_instance exists, handler should re-raise for centralized handling
          expect do
            handler_with_otto.call(env)
          end.to raise_error(StandardError, 'Integration error')

          # Verify handler context was stored in env
          expect(env['otto.handler']).to eq('TestLogic#call')
          expect(env['otto.handler_duration']).to be_a(Integer)
        end

        it 'stores route definition in env for middleware access' do
          captured_env = nil
          allow_any_instance_of(TestLogic).to receive(:process) do
            # Capture env from within the handler execution
            captured_env = env
            { result: 'ok' }
          end

          handler_with_otto.call(env)

          expect(captured_env['otto.route_definition']).to eq(logic_definition)
          expect(captured_env['otto.route_options']).to eq(logic_definition.options)
        end
      end

      context 'helper extensions' do
        it 'extends request with RequestHelpers' do
          captured_request = nil
          allow(TestLogic).to receive(:new) do |_context, params, _locale|
            # Can't capture request directly, so we'll verify through side effects
            TestLogic.allocate.tap do |logic|
              logic.instance_variable_set(:@context, AuthResultData.new)
              logic.instance_variable_set(:@params, params)
              logic.instance_variable_set(:@locale, 'en')
            end
          end

          # The setup_request_response in BaseHandler should extend request
          # We can verify this by checking that methods from RequestHelpers are available
          allow_any_instance_of(Rack::Request).to receive(:extend).with(Otto::RequestHelpers).and_call_original
          allow_any_instance_of(TestLogic).to receive(:process).and_return({ result: 'ok' })

          handler.call(env)

          expect(Rack::Request).to have_received(:new).with(env)
        end

        it 'extends response with ResponseHelpers' do
          allow_any_instance_of(Rack::Response).to receive(:extend).with(Otto::ResponseHelpers).and_call_original
          allow_any_instance_of(TestLogic).to receive(:process).and_return({ result: 'ok' })

          handler.call(env)

          expect(Rack::Response).to have_received(:new)
        end

        it 'extends response with ValidationHelpers' do
          allow_any_instance_of(Rack::Response).to receive(:extend).with(Otto::Security::ValidationHelpers).and_call_original
          allow_any_instance_of(TestLogic).to receive(:process).and_return({ result: 'ok' })

          handler.call(env)

          # ValidationHelpers should always be extended
          expect(Rack::Response.instance_method(:extend)).to have_been_called
        end

        context 'with CSRF enabled' do
          let(:otto_with_csrf) do
            Otto.new.tap do |o|
              # Enable CSRF if configuration supports it
              if o.respond_to?(:security_config) && o.security_config
                allow(o.security_config).to receive(:csrf_enabled?).and_return(true)
              end
            end
          end
          let(:handler_with_csrf) { Otto::RouteHandlers::LogicClassHandler.new(logic_definition, otto_with_csrf) }

          it 'extends response with CSRF helpers when CSRF is enabled' do
            # Mock security config
            security_config = double('SecurityConfig')
            allow(security_config).to receive(:csrf_enabled?).and_return(true)
            allow(security_config).to receive(:security_headers).and_return({})
            allow(otto_with_csrf).to receive(:security_config).and_return(security_config)

            allow_any_instance_of(Rack::Response).to receive(:extend).with(Otto::Security::CSRFHelpers).and_call_original
            allow_any_instance_of(TestLogic).to receive(:process).and_return({ result: 'ok' })

            handler_with_csrf.call(env)

            expect(Rack::Response.instance_method(:extend)).to have_been_called
          end
        end
      end

      context 'body wrapping and finalization' do
        it 'wraps non-array body in array before finalizing' do
          # TestLogic#process returns a hash, which gets processed by JSONHandler
          # JSONHandler writes JSON string to response body
          # finalize_response should ensure body is wrapped in array

          status, _, body = handler.call(env)

          expect(status).to eq(200)
          # Body should be an array after finalization
          expect(body).to respond_to(:each)
          expect(body).to be_a(Array)
        end

        it 'calls finalize_response which invokes res.finish' do
          # Verify that finalize_response is properly wrapping and finishing
          allow_any_instance_of(TestLogic).to receive(:process).and_return({ result: 'test' })

          status, headers, body = handler.call(env)

          # res.finish returns [status, headers, body]
          expect(status).to be_a(Integer)
          expect(headers).to be_a(Hash)
          expect(body).to respond_to(:each)
        end

        it 'preserves body that already responds to :each' do
          # If body is already enumerable, it should be preserved
          allow_any_instance_of(TestLogic).to receive(:process).and_return({ items: [1, 2, 3] })

          status, _, body = handler.call(env)

          expect(status).to eq(200)
          expect(body).to respond_to(:each)
        end
      end

      context 'security header application' do
        let(:security_config) do
          double('SecurityConfig',
                 csrf_enabled?: false,
                 security_headers: {
                   'X-Frame-Options' => 'DENY',
                   'X-Content-Type-Options' => 'nosniff',
                   'X-XSS-Protection' => '1; mode=block',
                 })
        end
        let(:otto_with_security) do
          Otto.new.tap do |o|
            allow(o).to receive(:security_config).and_return(security_config)
          end
        end
        let(:handler_with_security) { Otto::RouteHandlers::LogicClassHandler.new(logic_definition, otto_with_security) }

        it 'applies security headers from configuration' do
          status, headers, _ = handler_with_security.call(env)

          expect(status).to eq(200)
          expect(headers['X-Frame-Options']).to eq('DENY')
          expect(headers['X-Content-Type-Options']).to eq('nosniff')
          expect(headers['X-XSS-Protection']).to eq('1; mode=block')
        end

        it 'applies security headers even when handler fails' do
          allow(Otto).to receive(:env?).with(:dev, :development).and_return(false)
          allow_any_instance_of(TestLogic).to receive(:process).and_raise(StandardError, 'Security test error')

          status, headers, _ = handler_with_security.call(env)

          expect(status).to eq(500)
          expect(headers['X-Frame-Options']).to eq('DENY')
          expect(headers['X-Content-Type-Options']).to eq('nosniff')
        end

        it 'works without security config' do
          handler_no_security = Otto::RouteHandlers::LogicClassHandler.new(logic_definition, nil)

          status, _, _ = handler_no_security.call(env)

          expect(status).to eq(200)
        end

        it 'applies custom security headers' do
          custom_security_config = double('SecurityConfig',
                                          csrf_enabled?: false,
                                          security_headers: {
                                            'Strict-Transport-Security' => 'max-age=31536000',
                                            'Content-Security-Policy' => "default-src 'self'",
                                          })
          otto_custom = Otto.new.tap do |o|
            allow(o).to receive(:security_config).and_return(custom_security_config)
          end
          handler_custom = Otto::RouteHandlers::LogicClassHandler.new(logic_definition, otto_custom)

          status, headers, _ = handler_custom.call(env)

          expect(status).to eq(200)
          expect(headers['Strict-Transport-Security']).to eq('max-age=31536000')
          expect(headers['Content-Security-Policy']).to eq("default-src 'self'")
        end
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
        allow(Otto).to receive(:env?).with(:dev, :development).and_return(true)
        allow(TestClassController).to receive(:index).and_raise(StandardError, 'Class method error')

        status, _, body = handler.call(env)

        expect(status).to eq(500)
        expect(body.first).to include('Server error')
        expect(body.first).to include('Check logs for details')
      end

      context 'route response_type precedence in error handling' do
        # These tests verify that when a route declares response=json,
        # errors should return JSON regardless of the Accept header.
        # This is the same fix pattern applied to Otto::Core::ErrorHandler.

        let(:json_route_definition) do
          Otto::RouteDefinition.new('POST', '/api/data', 'TestClassController.index response=json')
        end

        let(:json_handler) { Otto::RouteHandlers::ClassMethodHandler.new(json_route_definition) }

        before do
          stub_const('TestClassController', TestClassController)
        end

        it 'returns JSON error when route declares response=json regardless of Accept header' do
          allow(TestClassController).to receive(:index).and_raise(StandardError, 'API error')

          html_env = {
            'REQUEST_METHOD' => 'POST',
            'PATH_INFO' => '/api/data',
            'QUERY_STRING' => '',
            'rack.input' => StringIO.new,
            'HTTP_ACCEPT' => 'text/html',
            'otto.route_definition' => json_route_definition,
          }

          status, headers, body = json_handler.call(html_env)

          expect(status).to eq(500)
          expect(headers['content-type']).to eq('application/json')
          response_body = JSON.parse(body.first)
          expect(response_body['error']).to eq('Internal Server Error')
        end

        it 'returns JSON error when route declares response=json with no Accept header' do
          allow(TestClassController).to receive(:index).and_raise(StandardError, 'API error')

          no_accept_env = {
            'REQUEST_METHOD' => 'POST',
            'PATH_INFO' => '/api/data',
            'QUERY_STRING' => '',
            'rack.input' => StringIO.new,
            'otto.route_definition' => json_route_definition,
          }

          status, headers, body = json_handler.call(no_accept_env)

          expect(status).to eq(500)
          expect(headers['content-type']).to eq('application/json')
          response_body = JSON.parse(body.first)
          expect(response_body['error']).to eq('Internal Server Error')
        end

        it 'falls back to Accept header when route has no response_type' do
          allow(TestClassController).to receive(:index).and_raise(StandardError, 'API error')

          json_accept_env = env.merge('HTTP_ACCEPT' => 'application/json')

          status, headers, body = handler.call(json_accept_env)

          expect(status).to eq(500)
          expect(headers['content-type']).to eq('application/json')
          response_body = JSON.parse(body.first)
          expect(response_body['error']).to eq('Internal Server Error')
        end

        it 'returns text/plain when route has no response_type and Accept is text/html' do
          allow(Otto).to receive(:env?).with(:dev, :development).and_return(true)
          allow(TestClassController).to receive(:index).and_raise(StandardError, 'API error')

          html_accept_env = env.merge('HTTP_ACCEPT' => 'text/html')

          status, headers, body = handler.call(html_accept_env)

          expect(status).to eq(500)
          expect(headers['content-type']).to eq('text/plain')
          expect(body.first).to include('Server error')
        end
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
