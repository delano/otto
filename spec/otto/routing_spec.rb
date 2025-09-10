# frozen_string_literal: true
# spec/otto/routing_spec.rb

require 'spec_helper'

RSpec.describe Otto, 'request handling and routing' do
  let(:test_routes) do
    [
      'GET / TestApp.index',
      'GET /show/:id TestApp.show',
      'POST /create TestApp.create',
      'PUT /update/:id TestApp.update',
      'DELETE /delete/:id TestApp.destroy',
      'GET /error TestApp.error_test',
      'GET /custom TestApp.custom_headers',
      'GET /json TestApp.json_response',
      'GET /html TestApp.html_response',
      'GET /instance/:id TestInstanceApp#show',
    ]
  end

  let(:app) { create_minimal_otto(test_routes) }

  describe 'basic routing' do
    it 'handles GET requests to root' do
      env = mock_rack_env(method: 'GET', path: '/')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Hello World')

      debug_response(response)
    end

    it 'handles parameterized routes' do
      env = mock_rack_env(method: 'GET', path: '/show/123')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Showing 123')
    end

    it 'handles POST requests' do
      env = mock_rack_env(method: 'POST', path: '/create')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Created')
    end

    it 'handles instance method routes' do
      env = mock_rack_env(method: 'GET', path: '/instance/456')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Instance showing 456')
    end
  end

  describe 'security headers in responses' do
    it 'includes default security headers in all responses' do
      env = mock_rack_env(method: 'GET', path: '/')
      response = app.call(env)

      security_headers = extract_security_headers(response)

      expect(security_headers).to have_key('x-content-type-options')
      expect(security_headers).to have_key('x-xss-protection')
      expect(security_headers).to have_key('referrer-policy')

      puts "\n=== DEBUG: Response Security Headers ==="
      security_headers.each { |k, v| puts "  #{k}: #{v}" }
      puts "======================================\n"
    end

    it 'includes custom security headers when configured' do
      app.set_security_headers({ 'x-custom-security' => 'enabled' })

      env = mock_rack_env(method: 'GET', path: '/')
      response = app.call(env)

      headers = response[1]
      expect(headers['x-custom-security']).to eq('enabled')
    end
  end

  describe 'error handling' do
    it 'returns 404 for non-existent routes' do
      env = mock_rack_env(method: 'GET', path: '/nonexistent')
      response = app.call(env)

      expect(response[0]).to eq(404)
      expect(response[2].join).to eq('Not Found')

      debug_response(response)
    end

    it 'handles application errors gracefully' do
      env = mock_rack_env(method: 'GET', path: '/error')
      response = app.call(env)

      expect(response[0]).to eq(500)
      expect(response[1]['content-type']).to eq('text/plain')

      body = response[2].join
      expect(body).to include('error occurred') if Otto.env?(:production)

      puts "\n=== DEBUG: Error Response ==="
      puts "Status: #{response[0]}"
      puts "Body: #{body}"
      puts "===========================\n"
    end

    it 'includes error ID in development mode' do
      original_env = ENV.fetch('RACK_ENV', nil)
      ENV['RACK_ENV'] = 'development'

      begin
        env = mock_rack_env(method: 'GET', path: '/error')
        response = app.call(env)

        body = response[2].join
        expect(body).to match(/ID: [a-f0-9]{16}/)
      ensure
        ENV['RACK_ENV'] = original_env
      end
    end

    it 'returns JSON error response when Accept header includes application/json' do
      env = mock_rack_env(method: 'GET', path: '/error', headers: { 'ACCEPT' => 'application/json' })
      response = app.call(env)

      expect(response[0]).to eq(500)
      expect(response[1]['content-type']).to eq('application/json')

      body = response[2].join
      parsed = JSON.parse(body)
      expect(parsed['error']).to eq('Internal Server Error')
      expect(parsed['message']).to include('error occurred')

      puts "\n=== DEBUG: JSON Error Response ==="
      puts "Status: #{response[0]}"
      puts "Content-Type: #{response[1]['content-type']}"
      puts "Body: #{body}"
      puts "===============================\n"
    end

    it 'returns JSON error response with error ID in development mode' do
      original_env = ENV.fetch('RACK_ENV', nil)
      ENV['RACK_ENV'] = 'development'

      begin
        env = mock_rack_env(method: 'GET', path: '/error', headers: { 'ACCEPT' => 'application/json' })
        response = app.call(env)

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('application/json')

        body = response[2].join
        parsed = JSON.parse(body)
        expect(parsed['error']).to eq('Internal Server Error')
        expect(parsed['message']).to include('Server error occurred')
        expect(parsed['error_id']).to match(/[a-f0-9]{16}/)
      ensure
        ENV['RACK_ENV'] = original_env
      end
    end

    it 'handles mixed Accept headers correctly (browser-style)' do
      # Typical browser Accept header that includes application/json
      accept_header = 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7'
      env = mock_rack_env(method: 'GET', path: '/error', headers: { 'ACCEPT' => accept_header })
      response = app.call(env)

      expect(response[0]).to eq(500)
      expect(response[1]['content-type']).to eq('application/json')

      body = response[2].join
      parsed = JSON.parse(body)
      expect(parsed['error']).to eq('Internal Server Error')
    end
  end

  describe 'HEAD request handling' do
    it 'handles HEAD requests like GET but without body' do
      env = mock_rack_env(method: 'HEAD', path: '/')
      response = app.call(env)

      expect(response[0]).to eq(200)
      # HEAD responses should have headers but empty body
      expect(response[1]).to be_a(Hash)
    end
  end
end
