# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::CSRFMiddleware do
  let(:config) { Otto::Security::Config.new }
  let(:app) { ->(env) { [200, { 'content-type' => 'text/html' }, ['<html><head></head><body>Hello</body></html>']] } }
  let(:middleware) { described_class.new(app, config) }

  before do
    config.enable_csrf_protection!
  end

  describe 'initialization' do
    it 'initializes with app and config' do
      expect(middleware).to be_an_instance_of(described_class)
    end

    it 'uses default config when none provided' do
      default_middleware = described_class.new(app)
      expect(default_middleware).to be_an_instance_of(described_class)
    end
  end

  describe 'safe method handling' do
    %w[GET HEAD OPTIONS TRACE].each do |method|
      it "allows #{method} requests without CSRF token" do
        env = mock_rack_env(method: method, path: '/')
        response = middleware.call(env)

        expect(response[0]).to eq(200)

        puts "\n=== DEBUG: Safe Method #{method} ==="
        puts "Status: #{response[0]}"
        puts "Headers: #{response[1].keys.join(', ')}"
        puts "===============================\n"
      end
    end

    it 'injects CSRF token into HTML responses for safe methods' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = { 'session_id' => 'test_session_safe' }
      env['HTTP_COOKIE'] = 'session_id=test_session_safe'
      response = middleware.call(env)

      body = response[2].join
      expect(body).to include('<meta name="csrf-token"')
      expect(body).to match(/content="[a-f0-9]{64}:[a-f0-9]{64}"/)

      puts "\n=== DEBUG: CSRF Token Injection ==="
      puts "Original body length: #{app.call(env)[2].join.length}"
      puts "Modified body length: #{body.length}"
      puts "Token meta tag present: #{body.include?('<meta name="csrf-token"')}"
      if body.match(/content="([^"]+)"/)
        token = body.match(/content="([^"]+)"/)[1]
        puts "Extracted token: #{token}"
        puts "Token format valid: #{token.include?(':') && token.split(':').length == 2}"
      end
      puts "===============================\n"
    end

    it 'does not inject token into non-HTML responses' do
      json_app = ->(env) { [200, { 'content-type' => 'application/json' }, ['{"message": "hello"}']] }
      json_middleware = described_class.new(json_app, config)

      env = mock_rack_env(method: 'GET', path: '/')
      response = json_middleware.call(env)

      body = response[2].join
      expect(body).not_to include('<meta name="csrf-token"')
      expect(body).to eq('{"message": "hello"}')
    end

    it 'handles responses without head tag gracefully' do
      no_head_app = ->(env) { [200, { 'content-type' => 'text/html' }, ['<body>No head tag</body>']] }
      no_head_middleware = described_class.new(no_head_app, config)

      env = mock_rack_env(method: 'GET', path: '/')
      response = no_head_middleware.call(env)

      body = response[2].join
      expect(body).not_to include('<meta name="csrf-token"')
      expect(body).to eq('<body>No head tag</body>')
    end

    it 'updates content-length header when token is injected' do
      env = mock_rack_env(method: 'GET', path: '/')
      response = middleware.call(env)

      body = response[2].join
      content_length = response[1]['content-length']

      if content_length
        expect(content_length.to_i).to eq(body.bytesize)

        puts "\n=== DEBUG: Content-Length Update ==="
        puts "Body size: #{body.bytesize}"
        puts "Content-Length header: #{content_length}"
        puts "Match: #{content_length.to_i == body.bytesize}"
        puts "===============================\n"
      end
    end
  end

  describe 'unsafe method validation' do
    %w[POST PUT DELETE PATCH].each do |method|
      context "for #{method} requests" do
        it 'rejects requests without CSRF token' do
          env = mock_rack_env(method: method, path: '/')
          response = middleware.call(env)

          expect(response[0]).to eq(403)
          expect(response[1]['content-type']).to eq('application/json')

          body = JSON.parse(response[2].join)
          expect(body['error']).to eq('CSRF token validation failed')

          puts "\n=== DEBUG: CSRF Rejection #{method} ==="
          puts "Status: #{response[0]}"
          puts "Error: #{body['error']}"
          puts "Message: #{body['message']}"
          puts "===============================\n"
        end

        it 'rejects requests with invalid CSRF token' do
          env = mock_rack_env(method: method, path: '/', params: { '_csrf_token' => 'invalid:token' })
          response = middleware.call(env)

          expect(response[0]).to eq(403)

          body = JSON.parse(response[2].join)
          expect(body['error']).to eq('CSRF token validation failed')
        end

        it 'accepts requests with valid CSRF token in params' do
          # First, generate a valid token
          session_id = 'test_session_123'
          valid_token = config.generate_csrf_token(session_id)

          # Mock request with session
          env = mock_rack_env(method: method, path: '/', params: { '_csrf_token' => valid_token })
          env['rack.session'] = { 'session_id' => session_id }

          response = middleware.call(env)

          expect(response[0]).to eq(200)

          puts "\n=== DEBUG: Valid CSRF Token #{method} ==="
          puts "Token: #{valid_token}"
          puts "Session ID: #{session_id}"
          puts "Status: #{response[0]}"
          puts "===============================\n"
        end

        it 'accepts requests with valid CSRF token in header' do
          session_id = 'test_session_456'
          valid_token = config.generate_csrf_token(session_id)

          env = mock_rack_env(method: method, path: '/', headers: { 'X-CSRF-Token' => valid_token })
          env['rack.session'] = { 'session_id' => session_id }

          response = middleware.call(env)

          expect(response[0]).to eq(200)
        end

        it 'tries alternative header format for AJAX requests' do
          session_id = 'ajax_session_789'
          valid_token = config.generate_csrf_token(session_id)

          env = mock_rack_env(method: method, path: '/')
          env['HTTP_X_REQUESTED_WITH'] = 'XMLHttpRequest'
          env['HTTP_X_CSRF_TOKEN'] = valid_token
          env['rack.session'] = { 'session_id' => session_id }

          response = middleware.call(env)

          expect(response[0]).to eq(200)

          puts "\n=== DEBUG: AJAX CSRF Token #{method} ==="
          puts "Token: #{valid_token}"
          puts "X-Requested-With: #{env['HTTP_X_REQUESTED_WITH']}"
          puts "Status: #{response[0]}"
          puts "===============================\n"
        end
      end
    end
  end

  describe 'session ID extraction' do
    it 'extracts session ID from rack session' do
      session_id = 'rack_session_test'
      env = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = { 'session_id' => session_id }

      # We need to access the private method for testing
      extracted_id = middleware.send(:extract_session_id, Rack::Request.new(env))
      expect(extracted_id).to eq(session_id)
    end

    it 'uses configurable session key for extraction' do
      # Create config with custom session key
      custom_config = Otto::Security::Config.new
      custom_config.enable_csrf_protection!
      custom_config.csrf_session_key = 'custom_session_key'
      custom_middleware = described_class.new(app, custom_config)

      session_id = 'custom_session_test'
      env = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = { 'custom_session_key' => session_id }

      extracted_id = custom_middleware.send(:extract_session_id, Rack::Request.new(env))
      expect(extracted_id).to eq(session_id)
    end

    it 'falls back to cookie-based session ID' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['HTTP_COOKIE'] = 'session_id=cookie_session_test'

      request = Rack::Request.new(env)
      extracted_id = middleware.send(:extract_session_id, request)
      expect(extracted_id).to eq('cookie_session_test')
    end

    it 'tries alternative cookie names' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['HTTP_COOKIE'] = '_session_id=alt_session_test'

      request = Rack::Request.new(env)
      extracted_id = middleware.send(:extract_session_id, request)
      expect(extracted_id).to eq('alt_session_test')
    end

    it 'creates session ID when none found' do
      env = mock_rack_env(method: 'GET', path: '/')
      request = Rack::Request.new(env)
      extracted_id = middleware.send(:extract_session_id, request)
      expect(extracted_id).to be_a(String)
      expect(extracted_id).not_to be_empty
    end
  end

  describe 'token extraction priority' do
    it 'prioritizes form parameter over header' do
      form_token = 'form_token_123:signature'
      header_token = 'header_token_456:signature'

      env = mock_rack_env(
        method: 'POST',
        path: '/',
        params: { '_csrf_token' => form_token },
        headers: { 'X-CSRF-Token' => header_token }
      )

      request = Rack::Request.new(env)
      extracted_token = middleware.send(:extract_csrf_token, request)
      expect(extracted_token).to eq(form_token)

      puts "\n=== DEBUG: Token Extraction Priority ==="
      puts "Form token: #{form_token}"
      puts "Header token: #{header_token}"
      puts "Extracted: #{extracted_token}"
      puts "Priority correct: #{extracted_token == form_token}"
      puts "=======================================\n"
    end

    it 'uses header when form parameter not present' do
      header_token = 'header_only_token:signature'

      env = mock_rack_env(method: 'POST', path: '/', headers: { 'X-CSRF-Token' => header_token })

      request = Rack::Request.new(env)
      extracted_token = middleware.send(:extract_csrf_token, request)
      expect(extracted_token).to eq(header_token)
    end

    it 'uses configured token key' do
      config.csrf_token_key = 'custom_csrf_key'
      custom_middleware = described_class.new(app, config)

      token = 'custom_key_token:signature'
      env = mock_rack_env(method: 'POST', path: '/', params: { 'custom_csrf_key' => token })

      request = Rack::Request.new(env)
      extracted_token = custom_middleware.send(:extract_csrf_token, request)
      expect(extracted_token).to eq(token)
    end
  end

  describe 'HTML response detection' do
    it 'detects HTML content type' do
      html_response = [200, { 'content-type' => 'text/html' }, ['<html></html>']]
      expect(middleware.send(:html_response?, html_response)).to be true
    end

    it 'detects HTML with charset' do
      html_response = [200, { 'content-type' => 'text/html; charset=utf-8' }, ['<html></html>']]
      expect(middleware.send(:html_response?, html_response)).to be true
    end

    it 'rejects non-HTML content types' do
      json_response = [200, { 'content-type' => 'application/json' }, ['{"key": "value"}']]
      expect(middleware.send(:html_response?, json_response)).to be false

      xml_response = [200, { 'content-type' => 'application/xml' }, ['<xml></xml>']]
      expect(middleware.send(:html_response?, xml_response)).to be false
    end

    it 'handles malformed responses' do
      expect(middleware.send(:html_response?, nil)).to be false
      expect(middleware.send(:html_response?, [])).to be false
      expect(middleware.send(:html_response?, [200])).to be false
    end

    it 'handles case-insensitive header keys' do
      mixed_case_response = [200, { 'Content-Type' => 'text/html' }, ['<html></html>']]
      expect(middleware.send(:html_response?, mixed_case_response)).to be true
    end
  end

  describe 'error response format' do
    it 'returns properly formatted JSON error' do
      env = mock_rack_env(method: 'POST', path: '/')
      response = middleware.call(env)

      expect(response[0]).to eq(403)
      expect(response[1]['content-type']).to eq('application/json')

      body = JSON.parse(response[2].join)
      expect(body).to have_key('error')
      expect(body).to have_key('message')
      expect(body['error']).to eq('CSRF token validation failed')

      content_length = response[1]['content-length']
      expect(content_length.to_i).to eq(response[2].join.bytesize)

      puts "\n=== DEBUG: Error Response Format ==="
      puts "Status: #{response[0]}"
      puts "Content-Type: #{response[1]['content-type']}"
      puts "Content-Length: #{content_length}"
      puts "Body: #{response[2].join}"
      puts "JSON valid: #{JSON.parse(response[2].join) rescue false}"
      puts "===============================\n"
    end
  end

  describe 'disabled CSRF protection' do
    let(:disabled_config) { Otto::Security::Config.new } # CSRF disabled by default
    let(:disabled_middleware) { described_class.new(app, disabled_config) }

    it 'bypasses CSRF checks when protection is disabled' do
      env = mock_rack_env(method: 'POST', path: '/')
      response = disabled_middleware.call(env)

      expect(response[0]).to eq(200)

      puts "\n=== DEBUG: Disabled CSRF Protection ==="
      puts "CSRF enabled: #{disabled_config.csrf_enabled?}"
      puts "POST without token status: #{response[0]}"
      puts "====================================\n"
    end

    it 'does not inject tokens when protection is disabled' do
      env = mock_rack_env(method: 'GET', path: '/')
      response = disabled_middleware.call(env)

      body = response[2].join
      expect(body).not_to include('<meta name="csrf-token"')
    end
  end

  describe 'edge cases and error conditions' do
    it 'handles requests with empty token parameter' do
      env = mock_rack_env(method: 'POST', path: '/', params: { '_csrf_token' => '' })
      response = middleware.call(env)

      expect(response[0]).to eq(403)
    end

    it 'handles requests with whitespace-only token' do
      env = mock_rack_env(method: 'POST', path: '/', params: { '_csrf_token' => '   ' })
      response = middleware.call(env)

      expect(response[0]).to eq(403)
    end

    it 'handles responses with array body' do
      array_app = ->(env) { [200, { 'content-type' => 'text/html' }, ['<html><head>', '</head><body>Hello</body></html>']] }
      array_middleware = described_class.new(array_app, config)

      env = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = { 'session_id' => 'test_session_array' }
      env['HTTP_COOKIE'] = 'session_id=test_session_array'
      response = array_middleware.call(env)

      body = response[2].join
      expect(body).to include('<meta name="csrf-token"')
    end

    it 'handles responses with non-string body' do
      object_body = Class.new do
        def to_s
          '<html><head></head><body>Object body</body></html>'
        end
      end.new

      object_app = ->(env) { [200, { 'content-type' => 'text/html' }, [object_body]] }
      object_middleware = described_class.new(object_app, config)

      env = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = { 'session_id' => 'test_session_object' }
      env['HTTP_COOKIE'] = 'session_id=test_session_object'
      response = object_middleware.call(env)

      body = response[2].join
      expect(body).to include('<meta name="csrf-token"')
    end

    it 'handles malformed HTML gracefully' do
      malformed_app = ->(env) { [200, { 'content-type' => 'text/html' }, ['<html><HEAD><body>Mixed case</body></html>']] }
      malformed_middleware = described_class.new(malformed_app, config)

      env = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = { 'session_id' => 'test_session_mixed' }
      env['HTTP_COOKIE'] = 'session_id=test_session_mixed'
      response = malformed_middleware.call(env)

      body = response[2].join
      # Should still inject token even with mixed case
      expect(body).to include('<meta name="csrf-token"')
    end
  end
end

RSpec.describe Otto::Security::CSRFHelpers do
  let(:config) do
    config = Otto::Security::Config.new
    config.enable_csrf_protection!
    config
  end
  let(:mock_response) do
    Class.new do
      include Otto::Security::CSRFHelpers

      attr_reader :otto, :req

      def initialize(otto, req)
        @otto = otto
        @req = req
        @csrf_token = nil
      end

    end
  end


  before do
    config.enable_csrf_protection!
  end

  describe 'CSRF helper methods' do
    let(:mock_session) { { 'session_id' => 'helper_test_session' } }
    let(:mock_request) do
      req = double('request')
      allow(req).to receive(:session).and_return(mock_session)
      allow(req).to receive(:cookies).and_return({})
      req
    end
    let(:mock_otto) do
      otto = double('otto')
      allow(otto).to receive(:security_config).and_return(config)
      allow(otto).to receive(:respond_to?).with(:security_config).and_return(true)
      otto
    end
    let(:response) { mock_response.new(mock_otto, mock_request) }

    describe '#csrf_token' do
      it 'generates CSRF token when not cached' do
        token = response.csrf_token
        expect(token).to be_a(String)
        expect(token).to include(':')

        parts = token.split(':')
        expect(parts.length).to eq(2)
      end

      it 'returns cached token on subsequent calls' do
        token1 = response.csrf_token
        token2 = response.csrf_token
        expect(token1).to eq(token2)
      end

      it 'handles missing otto gracefully' do
        no_security_otto = double('otto')
        allow(no_security_otto).to receive(:respond_to?).with(:security_config).and_return(false)
        no_otto_response = mock_response.new(no_security_otto, mock_request)
        expect(no_otto_response.csrf_token).to be_nil
      end
    end

    describe '#csrf_meta_tag' do
      it 'generates HTML meta tag with CSRF token' do
        meta_tag = response.csrf_meta_tag
        expect(meta_tag).to include('<meta name="csrf-token"')
        expect(meta_tag).to include('content="')
        expect(meta_tag).to end_with('">')

        # Extract token from meta tag
        token_match = meta_tag.match(/content="([^"]+)"/)
        expect(token_match).not_to be_nil
        token = token_match[1]

        expect(token).to include(':')
      end
    end

    describe '#csrf_form_tag' do
      it 'generates hidden form input with CSRF token' do
        form_tag = response.csrf_form_tag
        expect(form_tag).to include('<input type="hidden"')
        expect(form_tag).to include('name="_csrf_token"')
        expect(form_tag).to include('value="')

        # Extract token from form tag
        token_match = form_tag.match(/value="([^"]+)"/)
        expect(token_match).not_to be_nil
        token = token_match[1]
        expect(token).to include(':')
      end
    end

    describe '#csrf_token_key' do
      it 'returns configured CSRF token key' do
        expect(response.csrf_token_key).to eq('_csrf_token')
      end

      it 'returns default when otto not available' do
        no_otto_response = mock_response.new(nil, mock_request)
        expect(no_otto_response.csrf_token_key).to eq('_csrf_token')
      end

      it 'uses custom token key when configured' do
        config.csrf_token_key = 'custom_token_key'
        expect(response.csrf_token_key).to eq('custom_token_key')
      end
    end

    describe 'helper consistency' do
      it 'uses same token across all helpers' do
        token = response.csrf_token
        meta_tag = response.csrf_meta_tag
        form_tag = response.csrf_form_tag

        expect(meta_tag).to include(token)
        expect(form_tag).to include(token)
      end
    end
  end
end
