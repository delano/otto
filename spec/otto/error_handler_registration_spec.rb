# spec/otto/error_handler_registration_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'Error Handler Registration' do
  # Define test error classes
  class TestMissingResourceError < StandardError; end
  class TestExpiredResourceError < StandardError; end
  class TestRateLimitError < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after: 60)
      super(message)
      @retry_after = retry_after
    end
  end

  let(:test_app) { create_minimal_otto }
  let(:env) { mock_rack_env(method: 'GET', path: '/test', headers: { 'Accept' => 'application/json' }) }

  describe '#register_error_handler' do
    it 'registers an error handler with status code' do
      test_app.register_error_handler(TestMissingResourceError, status: 404, log_level: :info)

      expect(test_app.error_handlers['TestMissingResourceError']).to eq({
        status: 404,
        log_level: :info,
        handler: nil
      })
    end

    it 'registers an error handler with custom block' do
      custom_handler = lambda { |error, _req|
        { error: 'Custom', message: error.message }
      }

      test_app.register_error_handler(TestMissingResourceError, status: 404, &custom_handler)

      config = test_app.error_handlers['TestMissingResourceError']
      expect(config[:status]).to eq(404)
      expect(config[:handler]).to eq(custom_handler)
    end

    it 'accepts error class as string for lazy loading' do
      test_app.register_error_handler('SomeModule::SomeError', status: 422, log_level: :warn)

      expect(test_app.error_handlers['SomeModule::SomeError']).to eq({
        status: 422,
        log_level: :warn,
        handler: nil
      })
    end

    it 'raises error when called after configuration is frozen' do
      Otto.unfreeze_for_testing(test_app)
      test_app.send(:freeze_configuration!)

      expect {
        test_app.register_error_handler(TestMissingResourceError, status: 404)
      }.to raise_error(FrozenError, /Cannot modify frozen configuration/)
    end
  end

  describe '#handle_expected_error' do
    before do
      test_app.register_error_handler(TestMissingResourceError, status: 404, log_level: :info)
      test_app.register_error_handler(TestExpiredResourceError, status: 410, log_level: :warn)
    end

    it 'returns configured status code for registered errors' do
      error = TestMissingResourceError.new('Resource not found')
      allow(Otto.logger).to receive(:info)

      response = test_app.send(:handle_error, error, env)

      expect(response[0]).to eq(404)
    end

    it 'logs at configured log level' do
      error = TestExpiredResourceError.new('Resource expired')

      expect(Otto).to receive(:structured_log).with(:warn, 'Expected error in request', hash_including(
        error: 'Resource expired',
        error_class: 'TestExpiredResourceError',
        expected: true
      ))

      test_app.send(:handle_error, error, env)
    end

    it 'returns JSON response for JSON requests' do
      error = TestMissingResourceError.new('Resource not found')
      allow(Otto.logger).to receive(:info)

      response = test_app.send(:handle_error, error, env)

      expect(response[0]).to eq(404)
      expect(response[1]['content-type']).to eq('application/json')

      body = JSON.parse(response[2].first)
      expect(body['error']).to eq('TestMissingResourceError')
      expect(body['message']).to eq('Resource not found')
    end

    it 'returns plain text response for non-JSON requests' do
      env['HTTP_ACCEPT'] = 'text/html'
      error = TestMissingResourceError.new('Resource not found')
      allow(Otto.logger).to receive(:info)

      response = test_app.send(:handle_error, error, env)

      expect(response[0]).to eq(404)
      expect(response[1]['content-type']).to eq('text/plain')
      expect(response[2].first).to include('TestMissingResourceError')
      expect(response[2].first).to include('Resource not found')
    end

    it 'includes error_id in development mode' do
      ENV['RACK_ENV'] = 'development'
      error = TestMissingResourceError.new('Resource not found')
      allow(Otto.logger).to receive(:info)

      response = test_app.send(:handle_error, error, env)
      body = JSON.parse(response[2].first)

      expect(body['error_id']).to match(/^[a-f0-9]{16}$/)

      ENV['RACK_ENV'] = 'test'
    end

    it 'excludes error_id in production mode' do
      ENV['RACK_ENV'] = 'production'
      error = TestMissingResourceError.new('Resource not found')
      allow(Otto.logger).to receive(:info)

      response = test_app.send(:handle_error, error, env)
      body = JSON.parse(response[2].first)

      expect(body).not_to have_key('error_id')

      ENV['RACK_ENV'] = 'test'
    end

    it 'uses custom handler block when provided' do
      test_app.register_error_handler(TestRateLimitError, status: 429, log_level: :warn) do |error, _req|
        {
          error: 'RateLimited',
          message: error.message,
          retry_after: error.retry_after
        }
      end

      error = TestRateLimitError.new('Too many requests', retry_after: 120)
      allow(Otto.logger).to receive(:warn)

      response = test_app.send(:handle_error, error, env)
      body = JSON.parse(response[2].first)

      expect(response[0]).to eq(429)
      expect(body['error']).to eq('RateLimited')
      expect(body['retry_after']).to eq(120)
    end

    it 'falls back to default response if custom handler fails' do
      test_app.register_error_handler(TestMissingResourceError, status: 404) do |_error, _req|
        raise StandardError, 'Handler failed'
      end

      error = TestMissingResourceError.new('Resource not found')

      # Allow the expected error log
      allow(Otto).to receive(:structured_log).with(:info, 'Expected error in request', anything)

      # Expect the warning about handler failure
      expect(Otto).to receive(:structured_log).with(:warn, 'Error in custom error handler', hash_including(
        error: 'Handler failed',
        error_class: 'StandardError',
        original_error_class: 'TestMissingResourceError'
      ))

      response = test_app.send(:handle_error, error, env)
      body = JSON.parse(response[2].first)

      expect(response[0]).to eq(404)
      expect(body['error']).to eq('TestMissingResourceError')
      expect(body['message']).to eq('Resource not found')
    end

    it 'falls back to default response if custom handler returns non-Hash' do
      test_app.register_error_handler(TestMissingResourceError, status: 404) do |_error, _req|
        'This is a string, not a Hash'  # Invalid return value
      end

      error = TestMissingResourceError.new('Resource not found')

      # Allow the expected error log
      allow(Otto).to receive(:structured_log).with(:info, 'Expected error in request', anything)

      # Expect the warning about non-hash return
      expect(Otto).to receive(:structured_log).with(:warn, 'Custom error handler returned non-hash value', hash_including(
        error_class: 'TestMissingResourceError',
        handler_result_class: 'String'
      ))

      response = test_app.send(:handle_error, error, env)
      body = JSON.parse(response[2].first)

      expect(response[0]).to eq(404)
      expect(body['error']).to eq('TestMissingResourceError')
      expect(body['message']).to eq('Resource not found')
    end

    it 'includes security headers in response' do
      secure_app = create_secure_otto
      secure_app.register_error_handler(TestMissingResourceError, status: 404, log_level: :info)

      error = TestMissingResourceError.new('Resource not found')
      allow(Otto.logger).to receive(:info)

      response = secure_app.send(:handle_error, error, env)

      security_headers = extract_security_headers(response)
      expect(security_headers).not_to be_empty
    end

    it 'marks expected errors in logs' do
      error = TestMissingResourceError.new('Resource not found')

      expect(Otto).to receive(:structured_log).with(:info, 'Expected error in request', hash_including(
        expected: true,
        error_class: 'TestMissingResourceError'
      ))

      test_app.send(:handle_error, error, env)
    end

    it 'does not log backtrace for expected errors' do
      error = TestMissingResourceError.new('Resource not found')
      allow(Otto).to receive(:structured_log)

      # Should not call log_backtrace for expected errors
      expect(Otto::LoggingHelpers).not_to receive(:log_backtrace)

      test_app.send(:handle_error, error, env)
    end

    context 'route response_type precedence' do
      it 'returns JSON when route declares response=json regardless of Accept header' do
        json_route = Otto::RouteDefinition.new('POST', '/api/data', 'ApiLogic response=json')
        html_env = mock_rack_env(method: 'POST', path: '/api/data', headers: { 'Accept' => 'text/html' })
        html_env['otto.route_definition'] = json_route

        error = TestMissingResourceError.new('Resource not found')
        allow(Otto.logger).to receive(:info)

        response = test_app.send(:handle_error, error, html_env)

        expect(response[0]).to eq(404)
        expect(response[1]['content-type']).to eq('application/json')
        body = JSON.parse(response[2].first)
        expect(body['error']).to eq('TestMissingResourceError')
        expect(body['message']).to eq('Resource not found')
      end

      it 'returns JSON when route declares response=json with no Accept header' do
        json_route = Otto::RouteDefinition.new('POST', '/api/data', 'ApiLogic response=json')
        env_no_accept = mock_rack_env(method: 'POST', path: '/api/data')
        env_no_accept.delete('HTTP_ACCEPT')
        env_no_accept['otto.route_definition'] = json_route

        error = TestMissingResourceError.new('Resource not found')
        allow(Otto.logger).to receive(:info)

        response = test_app.send(:handle_error, error, env_no_accept)

        expect(response[0]).to eq(404)
        expect(response[1]['content-type']).to eq('application/json')
      end

      it 'falls back to Accept header when route has no response_type' do
        default_route = Otto::RouteDefinition.new('GET', '/page', 'PageLogic')
        json_env = mock_rack_env(headers: { 'Accept' => 'application/json' })
        json_env['otto.route_definition'] = default_route

        error = TestMissingResourceError.new('Resource not found')
        allow(Otto.logger).to receive(:info)

        response = test_app.send(:handle_error, error, json_env)

        expect(response[0]).to eq(404)
        expect(response[1]['content-type']).to eq('application/json')
      end

      it 'returns text/plain when route has no response_type and Accept is text/html' do
        default_route = Otto::RouteDefinition.new('GET', '/page', 'PageLogic')
        html_env = mock_rack_env(headers: { 'Accept' => 'text/html' })
        html_env['otto.route_definition'] = default_route

        error = TestMissingResourceError.new('Resource not found')
        allow(Otto.logger).to receive(:info)

        response = test_app.send(:handle_error, error, html_env)

        expect(response[0]).to eq(404)
        expect(response[1]['content-type']).to eq('text/plain')
      end
    end
  end

  describe 'unregistered errors fallback to default behavior' do
    class UnregisteredError < StandardError; end

    it 'handles unregistered errors as 500' do
      error = UnregisteredError.new('Unexpected error')
      allow(Otto.logger).to receive(:error)

      response = test_app.send(:handle_error, error, env)

      expect(response[0]).to eq(500)
    end

    it 'logs unregistered errors at error level' do
      error = UnregisteredError.new('Unexpected error')

      expect(Otto).to receive(:structured_log).with(:error, 'Unhandled error in request', hash_including(
        error: 'Unexpected error',
        error_class: 'UnregisteredError'
      ))
      expect(Otto::LoggingHelpers).to receive(:log_backtrace)

      test_app.send(:handle_error, error, env)
    end
  end
end
