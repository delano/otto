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

      Otto.on_request_complete do |req, res, duration_ms, env|
        callback_called << {
          method: req.request_method,
          path: req.path_info,
          status: res[0],
          duration: duration_ms.is_a?(Numeric)
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
      Otto.on_request_complete { |_req, _res, _duration, _env| second_callback_called = true }

      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/test' }
      otto.call(env)

      expect(callback_called.length).to eq(1)
      expect(second_callback_called).to be true
    end

    it 'handles callback errors gracefully' do
      Otto.on_request_complete { |_req, _res, _duration, _env| raise 'Callback error' }

      expect(logger_double).to receive(:error).with(/Request completion hook error/)
      expect(logger_double).to receive(:debug).with(/Hook error backtrace/)

      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/test' }
      expect { otto.call(env) }.not_to raise_error
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
end
