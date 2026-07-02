# spec/otto/security/csp/writer_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::CSP::Writer do
  def build_config(enabled: true, debug: false)
    config = Otto::Security::Config.new
    config.enable_csp_with_nonce!(debug: debug) if enabled
    config
  end

  # Contract helper (see spec/support/nonce_csp_emission_examples.rb): drive the
  # Writer and return the caller's headers as it left them.
  def emit_csp(headers:, nonce:, mode: :override, enabled: true, development_mode: false)
    described_class.apply(headers, nonce, config: build_config(enabled: enabled), mode: mode,
                                          development_mode: development_mode)
    headers
  end

  include_examples 'a nonce-CSP emission surface'
  include_examples 'a CSP override surface'
  include_examples 'a CSP backstop surface'

  describe '.apply return value (Result)' do
    let(:config) { build_config }

    it 'returns an applied Result carrying the written policy and mode' do
      headers = { 'content-type' => 'text/html' }
      result = described_class.apply(headers, 'N', config: config, mode: :override)

      expect(result).to be_applied
      expect(result).not_to be_skipped
      expect(result.policy).to eq(headers['content-security-policy'])
      expect(result.policy).to include("'nonce-N'")
      expect(result.mode).to eq(:override)
      expect(result.skip_reason).to be_nil
    end

    it 'reports :disabled when nonce-CSP is off' do
      result = described_class.apply({ 'content-type' => 'text/html' }, 'N', config: build_config(enabled: false))
      expect(result.skip_reason).to eq(:disabled)
      expect(result.policy).to be_nil
    end

    it 'reports :disabled when config is nil' do
      result = described_class.apply({ 'content-type' => 'text/html' }, 'N', config: nil)
      expect(result).to be_skipped
      expect(result.skip_reason).to eq(:disabled)
    end

    it 'reports :blank_nonce for a nil/empty nonce' do
      expect(described_class.apply({ 'content-type' => 'text/html' }, nil, config: config).skip_reason).to eq(:blank_nonce)
      expect(described_class.apply({ 'content-type' => 'text/html' }, '', config: config).skip_reason).to eq(:blank_nonce)
    end

    it 'reports :non_html for a non-HTML response' do
      expect(described_class.apply({ 'content-type' => 'application/json' }, 'N', config: config).skip_reason).to eq(:non_html)
      expect(described_class.apply({}, 'N', config: config).skip_reason).to eq(:non_html)
    end

    it 'reports :existing_csp and returns the pre-existing policy in backstop mode' do
      headers = { 'content-type' => 'text/html', 'content-security-policy' => 'PRESET' }
      result = described_class.apply(headers, 'N', config: config, mode: :backstop)

      expect(result).to be_skipped
      expect(result.skip_reason).to eq(:existing_csp)
      expect(result.policy).to eq('PRESET')
      expect(headers['content-security-policy']).to eq('PRESET')
    end
  end

  describe 'in-place, key-scoped writes' do
    it 'mutates the caller hash in place (same object identity)' do
      headers = { 'content-type' => 'text/html' }
      described_class.apply(headers, 'N', config: build_config)
      expect(headers).to have_key('content-security-policy')
    end

    it 'leaves unrelated headers untouched' do
      headers = { 'content-type' => 'text/html', 'x-frame-options' => 'DENY' }
      described_class.apply(headers, 'N', config: build_config)
      expect(headers['x-frame-options']).to eq('DENY')
    end

    it 'does not touch the hash at all when it skips' do
      headers = { 'content-type' => 'application/json' }.freeze
      expect { described_class.apply(headers, 'N', config: build_config) }.not_to raise_error
    end
  end

  describe 'frozen headers (downstream Rack SPEC violation) fails loud' do
    it 'raises FrozenError when a write is attempted against a frozen hash' do
      headers = { 'content-type' => 'text/html' }.freeze
      expect { described_class.apply(headers, 'N', config: build_config) }.to raise_error(FrozenError)
    end
  end

  describe 'mode validation' do
    it 'raises ArgumentError for an unknown mode' do
      expect { described_class.apply({ 'content-type' => 'text/html' }, 'N', config: build_config, mode: :clobber) }
        .to raise_error(ArgumentError, /mode must be one of/)
    end
  end

  describe 'debug observability' do
    it 'logs the applied policy when debug_csp? is on' do
      config = build_config(debug: true)
      expect(Otto.logger).to receive(:debug).with(/\[CSP\] applied \(override\).*nonce-N/)
      described_class.apply({ 'content-type' => 'text/html' }, 'N', config: config)
    end

    it 'logs the skip reason when debug_csp? is on (skips are observable)' do
      config = build_config(debug: true)
      expect(Otto.logger).to receive(:debug).with('[CSP] skipped (non_html)')
      described_class.apply({ 'content-type' => 'application/json' }, 'N', config: config)
    end

    it 'does not log when debug_csp? is off' do
      expect(Otto.logger).not_to receive(:debug)
      described_class.apply({ 'content-type' => 'text/html' }, 'N', config: build_config(debug: false))
    end
  end
end
