# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe 'Otto Logging Integration' do
  let(:app_double) { double('app') }
  let(:logger_double) { double('logger', debug: nil, info: nil, warn: nil, error: nil) }
  let(:routes_content) do
    <<~ROUTES
      GET /test test_handler
      POST /auth auth_handler auth:authenticated
      GET /static/* static
    ROUTES
  end

  before do
    Otto.debug = true
    Otto.logger = logger_double
    allow(Otto.logger).to receive(:method).and_return(double(arity: 2))
  end

  after do
    Otto.debug = false
    Otto.logger = Logger.new($stdout)
  end

  describe 'structured logging functionality' do
    it 'provides structured_log helper method' do
      expect(Otto).to respond_to(:structured_log)

      expect(logger_double).to receive(:info).with('Test message', { key: 'value' })
      Otto.structured_log(:info, 'Test message', { key: 'value' })
    end

    it 'handles debug level with debug flag' do
      Otto.debug = true
      expect(logger_double).to receive(:debug).with('Debug message', { debug: true })
      Otto.structured_log(:debug, 'Debug message', { debug: true })
    end

    it 'skips debug logging when debug is false' do
      Otto.debug = false
      expect(logger_double).not_to receive(:debug)
      Otto.structured_log(:debug, 'Debug message', { debug: true })
    end
  end

  describe 'request completion hooks' do
    let(:otto) { Otto.new }
    let(:request_double) { double('request', request_method: 'GET', path_info: '/test') }
    let(:response) { [200, {}, ['OK']] }
    let(:callback_called) { [] }

    before do
      allow(Rack::Request).to receive(:new).and_return(request_double)
      allow(otto.instance_variable_get(:@app)).to receive(:call).and_return(response)

      Otto.on_request_complete do |req, res, duration|
        callback_called << {
          method: req.request_method,
          path: req.path_info,
          status: res.status,
          duration: duration.is_a?(Numeric)
        }
      end
    end

    after do
      # Clear callbacks
      Otto.instance_variable_set(:@request_complete_callbacks, [])
    end

    it 'executes request completion hooks with timing' do
      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/test' }

      otto.call(env)

      expect(callback_called.length).to eq(1)
      expect(callback_called.first[:method]).to eq('GET')
      expect(callback_called.first[:path]).to eq('/test')
      expect(callback_called.first[:status]).to eq(200)
      expect(callback_called.first[:duration]).to be true
    end

    it 'handles multiple callbacks' do
      second_callback_called = false
      Otto.on_request_complete { |_req, _res, _duration| second_callback_called = true }

      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/test' }
      otto.call(env)

      expect(callback_called.length).to eq(1)
      expect(second_callback_called).to be true
    end

    it 'handles callback errors gracefully' do
      Otto.on_request_complete { |_req, _res, _duration| raise 'Callback error' }

      expect(logger_double).to receive(:error).with(/Request completion hook error/)
      expect(logger_double).to receive(:debug).with(/Hook error backtrace/)

      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/test' }
      expect { otto.call(env) }.not_to raise_error
    end

    it 'provides Rack::Response object with developer-friendly API' do
      response_object = nil
      Otto.on_request_complete do |_req, res, _duration|
        response_object = res
      end

      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/test' }
      otto.call(env)

      # Verify response is a Rack::Response with clean API
      expect(response_object).to be_a(Rack::Response)
      expect(response_object.status).to eq(200)
      expect(response_object.headers).to be_a(Hash)
      expect(response_object.body).to respond_to(:each)

      # Verify it can be converted back to tuple if needed
      tuple = response_object.finish
      expect(tuple).to be_a(Array)
      expect(tuple[0]).to eq(200)
    end
  end

  describe 'Otto.structured_log in action' do
    it 'logs route resolution events using structured logging' do
      # Test that we can log route matching events
      expect(logger_double).to receive(:debug).with('Route matched', hash_including(
        method: 'GET',
        path: '/test'
      ))

      Otto.structured_log(:debug, 'Route matched', {
        method: 'GET',
        path: '/test',
        handler: 'test_handler'
      })
    end

    it 'logs 404 events using structured logging' do
      expect(logger_double).to receive(:info).with('Route not found', hash_including(
        method: 'GET',
        path: '/nonexistent'
      ))

      Otto.structured_log(:info, 'Route not found', {
        method: 'GET',
        path: '/nonexistent',
        fallback_to: 'default_not_found'
      })
    end
  end

  describe 'LoggingHelpers.request_context' do
    it 'uses already-anonymized user agent from env (privacy enabled)' do
      # When privacy is enabled, IPPrivacyMiddleware has already replaced
      # env['HTTP_USER_AGENT'] with the anonymized version
      env = {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/test',
        'REMOTE_ADDR' => '192.168.1.0',  # Already masked
        'HTTP_USER_AGENT' => 'Mozilla/*.* (Macintosh; Intel Mac OS X *.*) Chrome/*.*',  # Already anonymized
        'otto.geo_country' => 'US'
      }

      context = Otto::LoggingHelpers.request_context(env)

      expect(context[:user_agent]).to eq('Mozilla/*.* (Macintosh; Intel Mac OS X *.*) Chrome/*.*')
      expect(context[:user_agent]).not_to include('141.0')
      expect(context[:user_agent]).not_to include('10_15_7')
    end

    it 'truncates long user agent strings (privacy disabled)' do
      # When privacy is disabled, env['HTTP_USER_AGENT'] contains the raw UA
      long_ua = 'Mozilla/5.0 ' + 'X' * 200
      env = {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/test',
        'REMOTE_ADDR' => '127.0.0.1',
        'HTTP_USER_AGENT' => long_ua  # Raw UA (privacy disabled)
      }

      context = Otto::LoggingHelpers.request_context(env)

      # Still truncated to 100 chars to prevent log bloat
      expect(context[:user_agent].length).to eq(100)
      expect(context[:user_agent]).to eq(long_ua[0..99])
    end

    it 'handles nil user agent gracefully' do
      env = {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/test',
        'REMOTE_ADDR' => '127.0.0.1'
      }

      context = Otto::LoggingHelpers.request_context(env)

      expect(context).not_to have_key(:user_agent)
    end

    it 'includes all expected request metadata' do
      # When privacy is enabled, IPPrivacyMiddleware has already replaced
      # env['HTTP_USER_AGENT'] with the anonymized version
      fingerprint = double('fingerprint', anonymized_ua: 'Mozilla/*.*')
      env = {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/api/endpoint',
        'REMOTE_ADDR' => '9.9.9.0',
        'HTTP_USER_AGENT' => 'Mozilla/*.*',  # Already anonymized by middleware
        'otto.privacy.fingerprint' => fingerprint,
        'otto.geo_country' => 'CH'
      }

      context = Otto::LoggingHelpers.request_context(env)

      expect(context).to eq({
        method: 'POST',
        path: '/api/endpoint',
        ip: '9.9.9.0',
        country: 'CH',
        user_agent: 'Mozilla/*.*'
      })
    end
  end

  describe 'LoggingHelpers timing methods' do
    let(:env) do
      {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/api/test',
        'REMOTE_ADDR' => '192.0.2.100',
        'HTTP_USER_AGENT' => 'TestAgent/1.0'
      }
    end

    describe '#log_timed_operation' do
      it 'logs successful operations with timing' do
        expect(logger_double).to receive(:info).with(
          'Operation completed',
          hash_including(
            method: 'POST',
            path: '/api/test',
            ip: '192.0.2.100',
            duration: kind_of(Integer),
            result: 'success'
          )
        )

        result = Otto::LoggingHelpers.log_timed_operation(:info, 'Operation completed', env, result: 'success') do
          sleep(0.001)
          'test_result'
        end

        expect(result).to eq('test_result')
      end

      it 'logs failed operations with error details' do
        expect(logger_double).to receive(:error).with(
          'Operation completed failed',
          hash_including(
            method: 'POST',
            path: '/api/test',
            duration: kind_of(Integer),
            error: 'Test error',
            error_class: 'StandardError'
          )
        )

        expect {
          Otto::LoggingHelpers.log_timed_operation(:info, 'Operation completed', env) do
            raise StandardError, 'Test error'
          end
        }.to raise_error(StandardError, 'Test error')
      end
    end

    describe '#log_with_metadata' do
      it 'formats metadata as key=value pairs' do
        expect(Otto.logger).to receive(:info).with(
          'Template compiled: template_type=handlebars cached=false duration=68'
        )

        Otto::LoggingHelpers.log_with_metadata(:info, 'Template compiled',
          template_type: 'handlebars',
          cached: false,
          duration: 68
        )
      end

      it 'handles empty metadata' do
        expect(Otto).to receive(:structured_log).with(:info, 'Simple message')

        Otto::LoggingHelpers.log_with_metadata(:info, 'Simple message')
      end
    end

    describe '#format_value' do
      it 'formats different value types correctly' do
        expect(Otto::LoggingHelpers.format_value('string')).to eq('string')
        expect(Otto::LoggingHelpers.format_value(42)).to eq('42')
        expect(Otto::LoggingHelpers.format_value(true)).to eq('true')
        expect(Otto::LoggingHelpers.format_value(false)).to eq('false')
        expect(Otto::LoggingHelpers.format_value(nil)).to eq('nil')
        expect(Otto::LoggingHelpers.format_value(['array'])).to eq('["array"]')
      end
    end
  end
end
