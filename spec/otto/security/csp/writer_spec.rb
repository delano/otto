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

  # Extras contract helper (see spec/support/csp_request_extras_examples.rb):
  # the Writer reads extras from the env passed via its env: kwarg, gated on
  # the config's boot-time opt-in.
  def emit_csp_with_env(headers:, nonce:, env:, extras_enabled: true)
    config = build_config
    config.enable_csp_request_extras! if extras_enabled
    described_class.apply(headers, nonce, config: config, env: env)
    headers
  end

  include_examples 'a nonce-CSP emission surface'
  include_examples 'a CSP override surface'
  include_examples 'a CSP backstop surface'
  include_examples 'a request-extras-aware CSP surface'

  describe 'request extras with a config lacking the extra_directives: kwarg' do
    # A duck-typed config frozen at the pre-#243 generate_nonce_csp signature:
    # passing extra_directives: to it would ArgumentError at request time.
    let(:legacy_config) do
      Class.new do
        def csp_nonce_enabled? = true

        def csp_request_extras_enabled? = true

        def generate_nonce_csp(nonce, development_mode: false)
          _ = development_mode
          "script-src 'nonce-#{nonce}'; form-action 'self';"
        end
      end.new
    end

    it 'never raises: falls back to the legacy call shape, drops the extras, and warns once' do
      allow(Otto).to receive(:structured_log)
      headers = { 'content-type' => 'text/html' }
      env = mock_rack_env(method: 'GET', path: '/legacy')
      env['otto.csp.extra_directives'] = { 'form-action' => ['https://idp.example.com'] }

      result = described_class.apply(headers, 'N', config: legacy_config, env: env)

      expect(result).to be_applied
      expect(result.extra_directives).to be_nil
      expect(headers['content-security-policy']).to eq("script-src 'nonce-N'; form-action 'self';")
      expect(Otto).to have_received(:structured_log)
        .with(:warn, 'CSP request extras dropped',
              hash_including(directives: 'form-action', reason: :config_without_extras_support,
                             path: '/legacy'))
        .once
    end
  end

  describe 'request extras applied/dropped accounting' do
    it 'excludes an absent-directive entry from Result#extra_directives and logs it with request context' do
      allow(Otto).to receive(:structured_log)
      config = build_config
      config.enable_csp_request_extras!
      config.csp_directive_overrides = { 'form-action' => nil } # boot removed it
      headers = { 'content-type' => 'text/html' }
      env = mock_rack_env(method: 'POST', path: '/signin')
      env['otto.csp.extra_directives'] = {
        'form-action' => ['https://idp.example.com'],
        'connect-src' => ['https://api.example.com'],
      }

      result = described_class.apply(headers, 'N', config: config, env: env)

      expect(result).to be_applied
      # Only what actually landed — the form-action entry was dropped by the
      # append (absent directive), so the Result must not claim it.
      expect(result.extra_directives).to eq('connect-src' => ['https://api.example.com'])
      expect(headers['content-security-policy']).not_to include('form-action')
      expect(headers['content-security-policy']).to include('https://api.example.com')
      expect(Otto).to have_received(:structured_log)
        .with(:warn, 'CSP request extra dropped',
              hash_including(directive: 'form-action', reason: :absent_directive,
                             method: 'POST', path: '/signin'))
    end

    it 'reports nil extras when every entry was dropped by the append' do
      allow(Otto).to receive(:structured_log)
      config = build_config
      config.enable_csp_request_extras!
      config.csp_directive_overrides = { 'form-action' => nil }
      headers = { 'content-type' => 'text/html' }
      env = { 'otto.csp.extra_directives' => { 'form-action' => ['https://idp.example.com'] } }

      result = described_class.apply(headers, 'N', config: config, env: env)

      expect(result).to be_applied
      expect(result.extra_directives).to be_nil
    end
  end

  describe 'request extras opt-in gating' do
    it 'treats a duck-typed config without the predicate as extras-disabled' do
      allow(Otto).to receive(:structured_log)
      duck_config = Class.new do
        def csp_nonce_enabled? = true

        def generate_nonce_csp(nonce, development_mode: false, extra_directives: nil)
          _ = development_mode
          _ = extra_directives
          "script-src 'nonce-#{nonce}'; form-action 'self';"
        end
      end.new
      headers = { 'content-type' => 'text/html' }
      env = { 'otto.csp.extra_directives' => { 'form-action' => ['https://idp.example.com'] } }

      result = described_class.apply(headers, 'N', config: duck_config, env: env)

      expect(result).to be_applied
      expect(result.extra_directives).to be_nil
      expect(headers['content-security-policy']).not_to include('idp.example.com')
      expect(Otto).not_to have_received(:structured_log)
    end
  end

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
