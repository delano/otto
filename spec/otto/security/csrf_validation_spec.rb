# spec/otto/security/csrf_validation_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Shared CSRF token mechanics mixed into CSRFEnforcementWrapper (issue #186).
# Exercised here through a minimal host that mirrors how the wrapper mixes the
# module in (an object exposing @config).
RSpec.describe Otto::Security::CSRFValidation do
  let(:host_class) do
    Class.new do
      include Otto::Security::CSRFValidation
      def initialize(config)
        @config = config
      end
    end
  end

  let(:config) do
    cfg = Otto::Security::Config.new
    cfg.enable_csrf_protection!
    cfg
  end

  let(:host) { host_class.new(config) }

  describe '#safe_method?' do
    %w[GET HEAD OPTIONS TRACE].each do |method|
      it "treats #{method} as safe" do
        expect(host.send(:safe_method?, method)).to be true
      end
    end

    %w[POST PUT DELETE PATCH].each do |method|
      it "treats #{method} as unsafe" do
        expect(host.send(:safe_method?, method)).to be false
      end
    end

    it 'is case-insensitive' do
      expect(host.send(:safe_method?, 'get')).to be true
    end
  end

  describe '#extract_session_id' do
    it 'extracts session ID from rack session' do
      session_id = 'rack_session_test'
      env = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = { 'session_id' => session_id }

      expect(host.send(:extract_session_id, Rack::Request.new(env))).to eq(session_id)
    end

    it 'uses a configurable session key' do
      config.csrf_session_key = 'custom_session_key'
      session_id = 'custom_session_test'
      env = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = { 'custom_session_key' => session_id }

      expect(host.send(:extract_session_id, Rack::Request.new(env))).to eq(session_id)
    end

    it 'falls back to cookie-based session ID' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['HTTP_COOKIE'] = 'session_id=cookie_session_test'

      expect(host.send(:extract_session_id, Rack::Request.new(env))).to eq('cookie_session_test')
    end

    it 'tries alternative cookie names' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['HTTP_COOKIE'] = '_session_id=alt_session_test'

      expect(host.send(:extract_session_id, Rack::Request.new(env))).to eq('alt_session_test')
    end

    it 'creates a session ID when none is found' do
      env = mock_rack_env(method: 'GET', path: '/')
      extracted = host.send(:extract_session_id, Rack::Request.new(env))

      expect(extracted).to be_a(String)
      expect(extracted).not_to be_empty
    end
  end

  describe '#extract_csrf_token' do
    it 'prioritizes the form parameter over the header' do
      form_token = 'form_token_123:signature'
      header_token = 'header_token_456:signature'
      env = mock_rack_env(
        method: 'POST',
        path: '/',
        params: { '_csrf_token' => form_token },
        headers: { 'X-CSRF-Token' => header_token }
      )

      expect(host.send(:extract_csrf_token, Rack::Request.new(env))).to eq(form_token)
    end

    it 'uses the header when the form parameter is absent' do
      header_token = 'header_only_token:signature'
      env = mock_rack_env(method: 'POST', path: '/', headers: { 'X-CSRF-Token' => header_token })

      expect(host.send(:extract_csrf_token, Rack::Request.new(env))).to eq(header_token)
    end

    it 'uses the configured token key' do
      config.csrf_token_key = 'custom_csrf_key'
      token = 'custom_key_token:signature'
      env = mock_rack_env(method: 'POST', path: '/', params: { 'custom_csrf_key' => token })

      expect(host.send(:extract_csrf_token, Rack::Request.new(env))).to eq(token)
    end
  end

  describe '#valid_csrf_token?' do
    it 'accepts a valid token for the request session' do
      session_id = 'valid-session'
      token = config.generate_csrf_token(session_id)
      env = mock_rack_env(method: 'POST', path: '/', params: { '_csrf_token' => token })
      env['rack.session'] = { 'session_id' => session_id }

      expect(host.send(:valid_csrf_token?, Rack::Request.new(env))).to be true
    end

    it 'rejects a missing token' do
      env = mock_rack_env(method: 'POST', path: '/')
      expect(host.send(:valid_csrf_token?, Rack::Request.new(env))).to be false
    end

    it 'short-circuits a whitespace-only token without touching session or HMAC' do
      env = mock_rack_env(method: 'POST', path: '/', params: { '_csrf_token' => '   ' })

      # The guard must reject before any session creation or verification runs.
      expect(config).not_to receive(:get_or_create_session_id)
      expect(config).not_to receive(:verify_csrf_token)
      expect(host.send(:valid_csrf_token?, Rack::Request.new(env))).to be false
    end
  end

  describe '#csrf_error_response' do
    it 'is a 403 JSON tuple with a matching content-length' do
      status, headers, body = host.send(:csrf_error_response)

      expect(status).to eq(403)
      expect(headers['content-type']).to eq('application/json')
      expect(headers['content-length'].to_i).to eq(body.join.bytesize)
      expect(JSON.parse(body.join)['error']).to eq('CSRF token validation failed')
    end

    it 'reuses one frozen body string across calls' do
      first = host.send(:csrf_error_response)[2].first
      second = host.send(:csrf_error_response)[2].first

      expect(first).to be_frozen
      expect(first).to equal(second) # same object, not re-serialized
    end
  end
end
