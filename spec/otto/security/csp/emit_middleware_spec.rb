# spec/otto/security/csp/emit_middleware_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::CSP::EmitMiddleware do
  let(:app_headers) { { 'content-type' => 'text/html' } }
  let(:seen_env) { {} }
  let(:app) do
    lambda do |env|
      seen_env.merge!(env)
      [200, app_headers.dup, ['<html></html>']]
    end
  end

  let(:config) do
    config = Otto::Security::Config.new
    config.enable_csp_with_nonce!
    config
  end

  let(:middleware) { described_class.new(app, config) }

  def get_env
    { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/' }
  end

  describe 'inert until configured' do
    it 'passes through untouched when nonce support is not enabled' do
      mw  = described_class.new(app, Otto::Security::Config.new)
      env = get_env

      _status, headers, = mw.call(env)

      expect(env).not_to have_key('otto.nonce')
      expect(headers).not_to have_key('content-security-policy')
    end
  end

  describe 'nonce exposure to the inner app' do
    it 'generates a nonce and exposes it in env BEFORE calling the app' do
      middleware.call(get_env)

      expect(seen_env['otto.nonce']).to be_a(String)
      expect(seen_env['otto.nonce']).not_to be_empty
    end

    it 'respects a nonce already present in env' do
      env = get_env.merge('otto.nonce' => 'upstream-nonce')

      _status, headers, = middleware.call(env)

      expect(seen_env['otto.nonce']).to eq('upstream-nonce')
      expect(headers['content-security-policy']).to include("'nonce-upstream-nonce'")
    end

    it 'reads/stores the nonce under a configurable key' do
      mw  = described_class.new(app, config, nonce_key: 'myapp.nonce')
      env = get_env

      _status, headers, = mw.call(env)

      expect(env['myapp.nonce']).to be_a(String)
      expect(env).not_to have_key('otto.nonce')
      expect(headers['content-security-policy']).to include("'nonce-#{env['myapp.nonce']}'")
    end

    it 'emits a header that agrees with the nonce views see' do
      env = get_env

      _status, headers, = middleware.call(env)

      expect(headers['content-security-policy']).to include("'nonce-#{env['otto.nonce']}'")
    end
  end

  describe 'applying the CSP at the raw-tuple boundary' do
    it 'applies the CSP to an HTML response' do
      _status, headers, body = middleware.call(get_env)

      expect(headers['content-security-policy']).to include('script-src')
      expect(body).to eq(['<html></html>'])
    end

    context 'when the downstream app uses canonically-cased headers' do
      let(:app_headers) { { 'Content-Type' => 'text/html; charset=utf-8' } }

      it 'still applies the CSP, without a duplicate header' do
        _status, headers, = middleware.call(get_env)

        expect(headers['content-security-policy']).to include('script-src')
        csp_keys = headers.keys.select { |k| k.casecmp?('content-security-policy') }
        expect(csp_keys.length).to eq(1)
      end
    end

    context 'when the app already set a CSP (canonically cased)' do
      let(:app_headers) do
        { 'Content-Type' => 'text/html', 'Content-Security-Policy' => "default-src 'self'" }
      end

      it 'defers to it (clobber: false) and does not emit a duplicate' do
        _status, headers, = middleware.call(get_env)

        expect(headers['content-security-policy']).to eq("default-src 'self'")
        csp_keys = headers.keys.select { |k| k.casecmp?('content-security-policy') }
        expect(csp_keys.length).to eq(1)
      end
    end

    context 'when the response is not HTML' do
      let(:app_headers) { { 'content-type' => 'application/json' } }

      it 'does not apply the CSP' do
        _status, headers, = middleware.call(get_env)

        expect(headers).not_to have_key('content-security-policy')
      end
    end

    it 'uses development directives when development_mode is set' do
      mw = described_class.new(app, config, development_mode: true)

      _status, headers, = mw.call(get_env)

      expect(headers['content-security-policy']).to include("'unsafe-inline'")
    end
  end

  describe 'integration with the Otto middleware stack' do
    it 'is injected with the Otto instance security config' do
      stack = Otto::Core::MiddlewareStack.new
      stack.add(described_class)

      base_app = ->(_env) { [200, { 'Content-Type' => 'text/html' }, ['ok']] }
      wrapped  = stack.wrap(base_app, config)

      env = get_env
      _status, headers, = wrapped.call(env)

      expect(headers['content-security-policy']).to include("'nonce-#{env['otto.nonce']}'")
    end
  end
end
