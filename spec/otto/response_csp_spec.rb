# spec/otto/response_csp_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Coverage for the Otto::Response nonce-CSP EMITTING surface: the #apply_csp
# helper (routed through the single apply core) and the deprecated
# #send_csp_headers shim whose historical quirks are now fixed by that core.
RSpec.describe Otto::Response do
  def build_config(enabled: true, debug: false)
    config = Otto::Security::Config.new
    config.enable_csp_with_nonce!(debug: debug) if enabled
    config
  end

  # Reset the one-time deprecation guard so each example observes it freshly.
  before { described_class.send_csp_headers_deprecation_warned = false }

  describe '#apply_csp' do
    # Contract helper (see spec/support/nonce_csp_emission_examples.rb).
    def emit_csp(headers:, nonce:, mode: :override, enabled: true, development_mode: false)
      response = described_class.new
      headers.each { |k, v| response.headers[k] = v }
      response.apply_csp(nonce, mode: mode, development_mode: development_mode,
                                security_config: build_config(enabled: enabled))
      response.headers
    end

    include_examples 'a nonce-CSP emission surface'
    include_examples 'a CSP override surface'
    include_examples 'a CSP backstop surface'

    it 'returns the Writer::Result' do
      response = described_class.new
      response.headers['content-type'] = 'text/html'
      result = response.apply_csp('N', security_config: build_config)

      expect(result).to be_a(Otto::Security::CSP::Writer::Result)
      expect(result).to be_applied
      expect(result.policy).to include("'nonce-N'")
    end

    it 'resolves the security config from the request env when not passed' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['otto.security_config'] = build_config
      response = described_class.new
      response.headers['content-type'] = 'text/html'
      response.request = Otto::Request.new(env)

      response.apply_csp('zzz')
      expect(response.headers['content-security-policy']).to include("'nonce-zzz'")
    end

    it 'does not set the Content-Type (caller owns it)' do
      response = described_class.new
      result = response.apply_csp('N', security_config: build_config)

      expect(response.headers).not_to have_key('content-security-policy')
      expect(result.skip_reason).to eq(:non_html)
    end
  end

  describe '#send_csp_headers (deprecated shim)' do
    let(:response) { described_class.new }

    it 'emits a nonce-based CSP policy when nonce support is enabled' do
      response.send_csp_headers('text/html', 'abc123', security_config: build_config)

      expect(response.headers['content-security-policy']).to include("script-src 'nonce-abc123'")
      expect(response.headers['content-type']).to eq('text/html')
    end

    it 'sets Content-Type only when not already set' do
      response.headers['content-type'] = 'text/html; charset=utf-8'
      response.send_csp_headers('text/plain', 'abc123', security_config: build_config)

      expect(response.headers['content-type']).to eq('text/html; charset=utf-8')
    end

    it 'does nothing (no CSP) when nonce support is disabled' do
      response.send_csp_headers('text/html', 'abc123', security_config: build_config(enabled: false))

      expect(response.headers).not_to have_key('content-security-policy')
      expect(response.headers['content-type']).to eq('text/html') # set before the skip
    end

    it 'does nothing when no security config can be resolved' do
      response.send_csp_headers('text/html', 'abc123')
      expect(response.headers).not_to have_key('content-security-policy')
    end

    it 'resolves the security config from the request env' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['otto.security_config'] = build_config
      response.request = Otto::Request.new(env)

      response.send_csp_headers('text/html', 'zzz')
      expect(response.headers['content-security-policy']).to include("'nonce-zzz'")
    end

    it 'uses development directives when development_mode is set' do
      response.send_csp_headers('text/html', 'devnonce',
                                security_config: build_config, development_mode: true)

      expect(response.headers['content-security-policy']).to include("script-src 'nonce-devnonce' 'unsafe-inline'")
    end

    context 'quirks now fixed by the apply core' do
      it 'skips a blank/nil nonce instead of emitting a broken nonce- policy' do
        response.send_csp_headers('text/html', '', security_config: build_config)
        expect(response.headers).not_to have_key('content-security-policy')

        response.send_csp_headers('text/html', nil, security_config: build_config)
        expect(response.headers).not_to have_key('content-security-policy')
      end

      it 'does not emit a CSP for a non-HTML (JSON) response' do
        response.send_csp_headers('application/json', 'abc123', security_config: build_config)
        expect(response.headers).not_to have_key('content-security-policy')
      end

      it 'overrides an existing CSP WITHOUT writing to stderr (override is deliberate now)' do
        response.headers['content-security-policy'] = "default-src 'self'"

        expect do
          response.send_csp_headers('text/html', 'abc123', security_config: build_config)
        end.not_to output.to_stderr

        expect(response.headers['content-security-policy']).to include("'nonce-abc123'")
      end
    end

    context 'deprecation notice' do
      it 'warns once via Otto.logger (not stderr)' do
        expect(Otto.logger).to receive(:warn).with(/#send_csp_headers is deprecated/).once

        response.send_csp_headers('text/html', 'abc123', security_config: build_config)
        # A second call in the same process does not warn again.
        described_class.new.send_csp_headers('text/html', 'abc123', security_config: build_config)
      end
    end
  end
end
