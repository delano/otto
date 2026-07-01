# spec/otto/security/write_nonce_csp_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Unit coverage for Otto::Security::Config#write_nonce_csp — the single,
# casing-safe nonce-CSP apply core shared by Otto::Response#send_csp_headers,
# Otto::Security::CSP::EmitMiddleware, and downstream raw-tuple boundaries
# (delano/otto#179). Pins the guard logic (enabled / nonce present / HTML-only /
# don't-clobber), the case-insensitive lookups, and the return-value contract
# (plain Hash in -> Rack::Headers COPY out; Rack::Headers in -> same object).
RSpec.describe Otto::Security::Config, '#write_nonce_csp' do
  subject(:config) do
    config = described_class.new
    config.enable_csp_with_nonce!
    config
  end

  let(:nonce) { 'abc123' }

  describe 'casing safety at a raw-tuple boundary' do
    it 'emits for a plain Hash with a canonically-cased Content-Type' do
      headers = { 'Content-Type' => 'text/html; charset=utf-8' }

      result = config.write_nonce_csp(headers, nonce)

      expect(result['content-security-policy']).to include("'nonce-abc123'")
    end

    it 'defers to a canonically-cased Content-Security-Policy without duplicating it' do
      headers = {
        'Content-Type' => 'text/html',
        'Content-Security-Policy' => "default-src 'self'",
      }

      result = config.write_nonce_csp(headers, nonce)

      expect(result['content-security-policy']).to eq("default-src 'self'")
      csp_keys = result.keys.select { |k| k.casecmp?('content-security-policy') }
      expect(csp_keys.length).to eq(1)
    end

    it 'overrides a canonically-cased CSP with clobber: true, still without a duplicate' do
      headers = {
        'Content-Type' => 'text/html',
        'Content-Security-Policy' => "default-src 'self'",
      }

      result = config.write_nonce_csp(headers, nonce, clobber: true)

      expect(result['content-security-policy']).to include("'nonce-abc123'")
      csp_keys = result.keys.select { |k| k.casecmp?('content-security-policy') }
      expect(csp_keys.length).to eq(1)
    end
  end

  describe 'guards' do
    it 'skips (headers unchanged) when nonce support is not enabled' do
      disabled = described_class.new
      headers  = { 'content-type' => 'text/html' }

      result = disabled.write_nonce_csp(headers, nonce)

      expect(result).to equal(headers)
      expect(result).not_to have_key('content-security-policy')
    end

    it 'skips when the nonce is nil' do
      headers = { 'content-type' => 'text/html' }

      result = config.write_nonce_csp(headers, nil)

      expect(result).to equal(headers)
      expect(result).not_to have_key('content-security-policy')
    end

    it 'skips when the nonce is empty' do
      headers = { 'content-type' => 'text/html' }

      result = config.write_nonce_csp(headers, '')

      expect(result).to equal(headers)
      expect(result).not_to have_key('content-security-policy')
    end

    it 'skips non-HTML responses' do
      headers = { 'content-type' => 'application/json' }

      result = config.write_nonce_csp(headers, nonce)

      expect(result).not_to have_key('content-security-policy')
    end

    it 'skips when there is no content-type at all' do
      result = config.write_nonce_csp({}, nonce)

      expect(result).not_to have_key('content-security-policy')
    end
  end

  describe 'return-value contract' do
    it 'wraps a plain Hash in Rack::Headers, leaving the original untouched (COPY)' do
      headers = { 'Content-Type' => 'text/html' }

      result = config.write_nonce_csp(headers, nonce)

      expect(result).to be_a(Rack::Headers)
      expect(result).not_to equal(headers)
      expect(headers).not_to have_key('content-security-policy')
      expect(headers).not_to have_key('Content-Security-Policy')
    end

    it 'mutates and returns the SAME object for Rack::Headers input' do
      headers = Rack::Headers['content-type' => 'text/html']

      result = config.write_nonce_csp(headers, nonce)

      expect(result).to equal(headers)
      expect(headers['content-security-policy']).to include("'nonce-abc123'")
    end
  end

  describe 'policy generation' do
    it 'uses development directives when development_mode is set' do
      headers = { 'content-type' => 'text/html' }

      result = config.write_nonce_csp(headers, nonce, development_mode: true)

      expect(result['content-security-policy'])
        .to include("script-src 'nonce-abc123' 'unsafe-inline'")
    end

    it 'matches generate_nonce_csp output exactly' do
      headers = { 'content-type' => 'text/html' }

      result = config.write_nonce_csp(headers, nonce)

      expect(result['content-security-policy']).to eq(config.generate_nonce_csp(nonce))
    end
  end
end
