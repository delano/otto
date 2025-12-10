# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Otto Request/Response Helper Registration' do
  let(:routes_file) { create_test_routes_file('routes_basic.txt', ['GET / TestApp.index']) }

  describe 'Otto::Request' do
    it 'is a subclass of Rack::Request' do
      expect(Otto::Request.superclass).to eq(Rack::Request)
    end

    it 'has access to framework helpers' do
      env = mock_rack_env(method: 'GET', path: '/')
      req = Otto::Request.new(env)
      expect(req).to respond_to(:masked_ip)
      expect(req).to respond_to(:geo_country)
      expect(req).to respond_to(:check_locale!)
    end
  end

  describe 'Otto::Response' do
    it 'is a subclass of Rack::Response' do
      expect(Otto::Response.superclass).to eq(Rack::Response)
    end

    it 'has access to framework helpers' do
      res = Otto::Response.new
      expect(res).to respond_to(:send_secure_cookie)
      expect(res).to respond_to(:no_cache!)
      expect(res).to respond_to(:app_path)
    end
  end

  describe '#register_request_helpers' do
    it 'accepts a module and includes it in request class' do
      custom_module = Module.new do
        def custom_method
          'custom_value'
        end
      end

      otto = Otto.new(routes_file)
      otto.register_request_helpers(custom_module)

      env = mock_rack_env(method: 'GET', path: '/')
      req = otto.request_class.new(env)
      expect(req.custom_method).to eq('custom_value')
    end

    it 'accepts multiple modules at once' do
      module1 = Module.new do
        def method1; 'value1'; end
      end
      module2 = Module.new do
        def method2; 'value2'; end
      end

      otto = Otto.new(routes_file)
      otto.register_request_helpers(module1, module2)

      env = mock_rack_env(method: 'GET', path: '/')
      req = otto.request_class.new(env)
      expect(req.method1).to eq('value1')
      expect(req.method2).to eq('value2')
    end

    it 'raises ArgumentError if argument is not a Module' do
      otto = Otto.new(routes_file)
      expect {
        otto.register_request_helpers("not_a_module")
      }.to raise_error(ArgumentError, /Expected Module, got String/)
    end

    it 'raises FrozenError after configuration is frozen' do
      otto = Otto.new(routes_file)
      otto.freeze_configuration! # Manually freeze configuration

      custom_module = Module.new { def custom; end }
      expect {
        otto.register_request_helpers(custom_module)
      }.to raise_error(FrozenError, /after first request/)
    end

    it 'prevents duplicate registration of same module' do
      custom_module = Module.new do
        def custom_method; 'value'; end
      end

      otto = Otto.new(routes_file)
      otto.register_request_helpers(custom_module)
      otto.register_request_helpers(custom_module) # Should not error

      # Should only be included once
      expect(otto.registered_request_helpers.count(custom_module)).to eq(1)
    end
  end

  describe '#register_response_helpers' do
    it 'accepts a module and includes it in response class' do
      custom_module = Module.new do
        def custom_response_method
          'custom_response_value'
        end
      end

      otto = Otto.new(routes_file)
      otto.register_response_helpers(custom_module)

      res = otto.response_class.new
      expect(res.custom_response_method).to eq('custom_response_value')
    end

    it 'accepts multiple modules at once' do
      module1 = Module.new do
        def method1; 'value1'; end
      end
      module2 = Module.new do
        def method2; 'value2'; end
      end

      otto = Otto.new(routes_file)
      otto.register_response_helpers(module1, module2)

      res = otto.response_class.new
      expect(res.method1).to eq('value1')
      expect(res.method2).to eq('value2')
    end

    it 'raises ArgumentError if argument is not a Module' do
      otto = Otto.new(routes_file)
      expect {
        otto.register_response_helpers(123)
      }.to raise_error(ArgumentError, /Expected Module, got Integer/)
    end

    it 'raises FrozenError after configuration is frozen' do
      otto = Otto.new(routes_file)
      otto.freeze_configuration! # Manually freeze configuration

      custom_module = Module.new { def custom; end }
      expect {
        otto.register_response_helpers(custom_module)
      }.to raise_error(FrozenError, /after first request/)
    end
  end

  describe 'custom helpers in routes' do
    it 'makes custom request helpers available in route handlers' do
      custom_module = Module.new do
        def current_user
          'test_user'
        end
      end

      # Create a test route that uses the custom helper
      test_class = Class.new do
        def self.show(req, res)
          res.write "User: #{req.current_user}"
          res.finish
        end
      end
      stub_const('TestLogic', test_class)

      routes_file = create_test_routes_file('test_routes.txt', ['GET /test TestLogic.show'])
      otto = Otto.new(routes_file)
      otto.register_request_helpers(custom_module)

      env = mock_rack_env(method: 'GET', path: '/test')
      status, _headers, body = otto.call(env)

      expect(status).to eq(200)
      expect(body.join).to include('User: test_user')
    end

    it 'makes custom response helpers available in route handlers' do
      custom_module = Module.new do
        def custom_json(data)
          headers['content-type'] = 'application/json'
          write JSON.generate(data)
        end
      end

      test_class = Class.new do
        def self.show(_req, res)
          res.custom_json({ message: 'success' })
          res.finish
        end
      end
      stub_const('TestLogic', test_class)

      routes_file = create_test_routes_file('test_routes.txt', ['GET /test TestLogic.show'])
      otto = Otto.new(routes_file)
      otto.register_response_helpers(custom_module)

      env = mock_rack_env(method: 'GET', path: '/test')
      status, headers, body = otto.call(env)

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('application/json')
      expect(JSON.parse(body.join)).to eq({ 'message' => 'success' })
    end
  end

  describe 'helper availability in middleware' do
    it 'framework helpers are available in middleware' do
      # Create middleware that uses request helpers
      test_middleware = Class.new do
        def initialize(app)
          @app = app
        end

        def call(env)
          req = Otto::Request.new(env)
          # Should have access to framework helpers
          env['test.has_masked_ip'] = req.respond_to?(:masked_ip)
          @app.call(env)
        end
      end

      test_class = Class.new do
        def self.show(_req, res)
          res.write "OK"
          res.finish
        end
      end
      stub_const('TestLogic', test_class)

      routes_file = create_test_routes_file('test_routes.txt', ['GET /test TestLogic.show'])
      otto = Otto.new(routes_file)
      otto.use test_middleware

      env = mock_rack_env(method: 'GET', path: '/test')
      otto.call(env)

      expect(env['test.has_masked_ip']).to be true
    end
  end

  describe '#registered_request_helpers and #registered_response_helpers' do
    it 'returns registered modules for debugging' do
      module1 = Module.new
      module2 = Module.new

      otto = Otto.new(routes_file)
      otto.register_request_helpers(module1)
      otto.register_response_helpers(module2)

      expect(otto.registered_request_helpers).to eq([module1])
      expect(otto.registered_response_helpers).to eq([module2])
    end

    it 'returns a copy to prevent external modification' do
      module1 = Module.new

      otto = Otto.new(routes_file)
      otto.register_request_helpers(module1)

      helpers = otto.registered_request_helpers
      helpers << Module.new

      # Original should be unchanged
      expect(otto.registered_request_helpers.length).to eq(1)
    end
  end
end
