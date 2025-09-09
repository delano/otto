# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'Error Handling' do
  let(:test_app) { create_minimal_otto }

  describe '#handle_error' do
    let(:env) { mock_rack_env(method: 'GET', path: '/test') }
    let(:error) do
      err = StandardError.new('Test error message')
      err.set_backtrace(['test:1:in `test_method`', 'test:2:in `another_method`'])
      err
    end

    it 'generates a unique error ID' do
      logged_messages = []
      allow(Otto.logger).to receive(:error) { |msg| logged_messages << msg }
      allow(Otto.logger).to receive(:debug)

      test_app.send(:handle_error, error, env)
      test_app.send(:handle_error, error, env)

      error_ids = logged_messages.join(' ').scan(/\[([a-f0-9]{16})\]/).flatten
      expect(error_ids.length).to be >= 2
      expect(error_ids.uniq.length).to eq(error_ids.length)
    end

    it 'logs error details with error ID' do
      expect(Otto.logger).to receive(:error).with(/\[[a-f0-9]{16}\] StandardError: Test error message/)
      allow(Otto.logger).to receive(:debug)

      test_app.send(:handle_error, error, env)
    end

    it 'logs backtrace when debug is enabled' do
      original_debug = Otto.debug
      Otto.debug = true

      # Allow initialization debug messages and focus on backtrace logging
      allow(Otto.logger).to receive(:debug)
      expect(Otto.logger).to receive(:error).with(/\[[a-f0-9]{16}\] StandardError: Test error message/)
      expect(Otto.logger).to receive(:debug).with(/\[[a-f0-9]{16}\] Backtrace:/).at_least(:once)

      test_app.send(:handle_error, error, env)

      Otto.debug = original_debug
    end

    it 'handles malformed request environment gracefully' do
      malformed_env = { 'INVALID' => 'ENV' }
      allow(Otto.logger).to receive(:error)

      expect { test_app.send(:handle_error, error, malformed_env) }.not_to raise_error
    end

    context 'when custom 500 route exists' do
      let(:custom_error_app) do
        routes_content = ['GET /500 TestErrorHandler.handle_error']
        create_minimal_otto(routes_content)
      end

      before do
        # Mock the TestErrorHandler class that follows the standard Otto pattern
        stub_const('TestErrorHandler', Class.new do
          def self.handle_error(req, res)
            error_id = req.env['otto.error_id']
            res.write("Custom error page (ID: #{error_id})")
          end
        end)
      end

      it 'uses custom 500 route when available' do
        allow(Otto.logger).to receive(:error)

        response = custom_error_app.send(:handle_error, error, env)

        expect(response[0]).to eq(200)  # Route handler should return 200, not 500
        expect(response[2].join).to match(/Custom error page \(ID: [a-f0-9]{16}\)/)
        expect(env['otto.error_id']).to match(/^[a-f0-9]{16}$/)
      end

      it 'falls back to built-in error response if custom handler fails' do
        # Mock custom handler to raise an error
        allow(TestErrorHandler).to receive(:handle_error).and_raise(RuntimeError, 'Handler error')
        allow(Otto.logger).to receive(:error)

        response = custom_error_app.send(:handle_error, error, env)

        expect(response[0]).to eq(500)
        expect(response[2].first).to match(/Server error|An error occurred/)
      end
    end

    context 'content negotiation' do
      it 'returns JSON response when client accepts JSON' do
        json_env = mock_rack_env(headers: { 'Accept' => 'application/json' })
        allow(Otto.logger).to receive(:error)

        response = test_app.send(:handle_error, error, json_env)

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('application/json')

        body = JSON.parse(response[2].first)
        expect(body).to include('error' => 'Internal Server Error')
      end

      it 'returns plain text response for non-JSON clients' do
        text_env = mock_rack_env(headers: { 'Accept' => 'text/html' })
        allow(Otto.logger).to receive(:error)

        response = test_app.send(:handle_error, error, text_env)

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('text/plain')
        expect(response[2].first).to be_a(String)
      end

      it 'handles missing Accept header gracefully' do
        env_no_accept = mock_rack_env
        env_no_accept.delete('HTTP_ACCEPT')
        allow(Otto.logger).to receive(:error)

        response = test_app.send(:handle_error, error, env_no_accept)

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('text/plain')
      end
    end

    it 'includes security headers in error response' do
      secure_app = create_secure_otto
      allow(Otto.logger).to receive(:error)

      response = secure_app.send(:handle_error, error, env)

      security_headers = extract_security_headers(response)
      expect(security_headers).not_to be_empty
    end
  end

  describe '#secure_error_response' do
    let(:error_id) { 'abc123def456' }

    context 'in development environment' do
      before { ENV['RACK_ENV'] = 'development' }
      after { ENV['RACK_ENV'] = 'test' }

      it 'includes error ID in response body' do
        response = test_app.send(:secure_error_response, error_id)

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('text/plain')
        expect(response[2].first).to include("ID: #{error_id}")
        expect(response[2].first).to include('Check logs for details')
      end
    end

    context 'in production environment' do
      before { ENV['RACK_ENV'] = 'production' }
      after { ENV['RACK_ENV'] = 'test' }

      it 'returns generic error message without ID' do
        response = test_app.send(:secure_error_response, error_id)

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('text/plain')
        expect(response[2].first).to eq('An error occurred. Please try again later.')
        expect(response[2].first).not_to include(error_id)
      end
    end

    it 'sets correct content-length header' do
      response = test_app.send(:secure_error_response, error_id)

      expected_length = response[2].first.bytesize
      expect(response[1]['content-length']).to eq(expected_length.to_s)
    end

    it 'includes security headers when security is enabled' do
      secure_app = create_secure_otto
      response = secure_app.send(:secure_error_response, error_id)

      security_headers = extract_security_headers(response)
      expect(security_headers).not_to be_empty
    end
  end

  describe '#json_error_response' do
    let(:error_id) { 'xyz789abc123' }

    context 'in development environment' do
      before { ENV['RACK_ENV'] = 'development' }
      after { ENV['RACK_ENV'] = 'test' }

      it 'includes error ID in JSON response' do
        response = test_app.send(:json_error_response, error_id)

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('application/json')

        body = JSON.parse(response[2].first)
        expect(body['error_id']).to eq(error_id)
        expect(body['error']).to eq('Internal Server Error')
        expect(body['message']).to include('Check logs for details')
      end
    end

    context 'in production environment' do
      before { ENV['RACK_ENV'] = 'production' }
      after { ENV['RACK_ENV'] = 'test' }

      it 'excludes error ID from production JSON response' do
        response = test_app.send(:json_error_response, error_id)

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('application/json')

        body = JSON.parse(response[2].first)
        expect(body).not_to have_key('error_id')
        expect(body['error']).to eq('Internal Server Error')
        expect(body['message']).to eq('An error occurred. Please try again later.')
      end
    end

    it 'generates valid JSON response' do
      response = test_app.send(:json_error_response, error_id)

      expect(response[1]['content-type']).to eq('application/json')
      expect { JSON.parse(response[2].first) }.not_to raise_error
    end

    it 'sets correct content-length header for JSON' do
      response = test_app.send(:json_error_response, error_id)

      expected_length = response[2].first.bytesize
      expect(response[1]['content-length']).to eq(expected_length.to_s)
    end

    it 'includes security headers in JSON error response' do
      secure_app = create_secure_otto
      response = secure_app.send(:json_error_response, error_id)

      security_headers = extract_security_headers(response)
      expect(security_headers).not_to be_empty
    end
  end

  describe 'error ID generation' do
    it 'generates unique 16-character hexadecimal error IDs' do
      logged_messages = []
      allow(Otto.logger).to receive(:error) { |msg| logged_messages << msg }

      test_error = StandardError.new('test')
      test_error.set_backtrace(['test:1:in `method`'])

      5.times do
        test_app.send(:handle_error, test_error, mock_rack_env)
      end

      error_ids = logged_messages.join(' ').scan(/\[([a-f0-9]{16})\]/).flatten

      expect(error_ids.length).to eq(5)
      expect(error_ids.uniq.length).to eq(5)
      error_ids.each { |id| expect(id).to match(/^[a-f0-9]{16}$/) }
    end
  end
end
