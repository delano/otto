# spec/otto/security/csp/emit_middleware_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::CSP::EmitMiddleware do
  def build_config(enabled: true, debug: false)
    config = Otto::Security::Config.new
    config.enable_csp_with_nonce!(debug: debug) if enabled
    config
  end

  # Contract helper (see spec/support/nonce_csp_emission_examples.rb). The
  # middleware is always a backstop; a provided nonce is simulated as one the
  # request CONSUMED (memoized in env), matching emit-if-consumed. `mode:` is
  # accepted for signature symmetry but the middleware is inherently :backstop.
  def emit_csp(headers:, nonce:, mode: :backstop, enabled: true, development_mode: false)
    config = build_config(enabled: enabled)
    env = { 'otto.security_config' => config }
    env['otto.nonce'] = nonce if nonce && !nonce.to_s.empty?
    app = ->(_e) { [200, headers, []] }
    _status, out_headers, = described_class.new(app, config, development_mode: development_mode).call(env)
    out_headers
  end

  include_examples 'a nonce-CSP emission surface'
  include_examples 'a CSP backstop surface'

  let(:enabled_config) { build_config }
  let(:html_headers) { { 'content-type' => 'text/html; charset=utf-8' } }

  def call_with(env:, headers:, config: enabled_config, **opts)
    app = ->(_e) { [200, headers, ['body']] }
    described_class.new(app, config, **opts).call(env)
  end

  describe 'inertness' do
    it 'is a transparent pass-through when nonce-CSP is disabled' do
      env = { 'otto.security_config' => build_config(enabled: false), 'otto.nonce' => 'N' }
      status, headers, body = call_with(env: env, headers: html_headers.dup, config: build_config(enabled: false))

      expect(status).to eq(200)
      expect(body).to eq(['body'])
      expect(headers).not_to have_key('content-security-policy')
    end

    it 'never mints a nonce when disabled, even in eager mode' do
      env = { 'otto.security_config' => build_config(enabled: false) }
      call_with(env: env, headers: html_headers.dup, config: build_config(enabled: false), eager: true)
      expect(env).not_to have_key('otto.nonce')
    end
  end

  describe 'emit-if-consumed (default)' do
    it 'does NOT emit when the request never consumed a nonce' do
      env = { 'otto.security_config' => enabled_config }
      _status, headers, = call_with(env: env, headers: html_headers.dup)

      expect(headers).not_to have_key('content-security-policy')
      expect(env).not_to have_key('otto.nonce') # and it did not mint one
    end

    it 'emits when a view consumed the nonce (memoized in env)' do
      env = { 'otto.security_config' => enabled_config, 'otto.nonce' => 'view-nonce' }
      _status, headers, = call_with(env: env, headers: html_headers.dup)

      expect(headers['content-security-policy']).to include("'nonce-view-nonce'")
    end

    it 'agrees with the env nonce (structural view/header agreement)' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['otto.security_config'] = enabled_config
      request = Otto::Request.new(env)
      consumed = request.csp_nonce # a "view" consumes the nonce

      _status, headers, = call_with(env: env, headers: html_headers.dup)
      expect(headers['content-security-policy']).to include("'nonce-#{consumed}'")
    end
  end

  describe 'eager mode' do
    it 'mints a nonce and emits even without consumption' do
      env = { 'otto.security_config' => enabled_config }
      headers = html_headers.dup
      call_with(env: env, headers: headers, eager: true)

      minted = env['otto.nonce']
      expect(minted).not_to be_nil
      expect(headers['content-security-policy']).to include("'nonce-#{minted}'")
    end

    it 'still defers to an existing CSP (backstop, never clobbers)' do
      env = { 'otto.security_config' => enabled_config }
      headers = html_headers.merge('content-security-policy' => 'PRESET')
      call_with(env: env, headers: headers, eager: true)

      expect(headers['content-security-policy']).to eq('PRESET')
    end
  end

  describe 'per-request development_mode callable' do
    it 'invokes the callable with the env to decide the directive set' do
      env = { 'otto.security_config' => enabled_config, 'otto.nonce' => 'N', 'dev' => true }
      dev = ->(e) { e['dev'] == true }
      _status, headers, = call_with(env: env, headers: html_headers.dup, development_mode: dev)

      expect(headers['content-security-policy']).to include("'nonce-N' 'unsafe-inline'")
    end

    it 'uses production directives when the callable returns false' do
      env = { 'otto.security_config' => enabled_config, 'otto.nonce' => 'N', 'dev' => false }
      dev = ->(e) { e['dev'] == true }
      _status, headers, = call_with(env: env, headers: html_headers.dup, development_mode: dev)

      expect(headers['content-security-policy']).to include("script-src 'nonce-N';")
      expect(headers['content-security-policy']).not_to include('unsafe-inline;')
    end
  end

  describe 'response passthrough' do
    it 'returns the same status and body the inner app produced' do
      env = { 'otto.security_config' => enabled_config, 'otto.nonce' => 'N' }
      status, _headers, body = call_with(env: env, headers: html_headers.dup)

      expect(status).to eq(200)
      expect(body).to eq(['body'])
    end
  end

  describe 'wiring' do
    it 'is registered as config-consuming middleware' do
      stack = Otto::Core::MiddlewareStack.new
      expect(stack.send(:middleware_needs_config?, described_class)).to be true
    end
  end
end
