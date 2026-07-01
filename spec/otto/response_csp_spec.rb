# spec/otto/response_csp_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Unit coverage for Otto::Response#send_csp_headers — the public, nonce-based
# CSP EMITTING half. It had zero direct coverage; this pins its branch logic:
# the csp_nonce_enabled? gate, security_config resolution (opts -> request env
# -> nil), the override-with-warning behavior, and development vs production
# directives.
RSpec.describe Otto::Response, '#send_csp_headers' do
  let(:response) { described_class.new }

  def nonce_config(debug: false)
    config = Otto::Security::Config.new
    config.enable_csp_with_nonce!(debug: debug)
    config
  end

  it 'emits a nonce-based CSP policy when nonce support is enabled' do
    response.send_csp_headers('text/html', 'abc123', security_config: nonce_config)

    csp = response.headers['content-security-policy']
    expect(csp).to include("script-src 'nonce-abc123'")
    expect(response.headers['content-type']).to eq('text/html')
  end

  it 'does nothing (no CSP header) when nonce support is disabled' do
    disabled = Otto::Security::Config.new # nonce not enabled

    response.send_csp_headers('text/html', 'abc123', security_config: disabled)

    expect(response.headers).not_to have_key('content-security-policy')
    # content-type is still set before the early return
    expect(response.headers['content-type']).to eq('text/html')
  end

  it 'does nothing when no security config can be resolved' do
    response.send_csp_headers('text/html', 'abc123')

    expect(response.headers).not_to have_key('content-security-policy')
  end

  it 'resolves the security config from the request env when not passed in opts' do
    env = mock_rack_env(method: 'GET', path: '/')
    env['otto.security_config'] = nonce_config
    response.request = Otto::Request.new(env)

    response.send_csp_headers('text/html', 'zzz')

    expect(response.headers['content-security-policy']).to include("'nonce-zzz'")
  end

  it 'overrides an existing CSP header and warns' do
    response.headers['content-security-policy'] = "default-src 'self'"

    expect do
      response.send_csp_headers('text/html', 'abc123', security_config: nonce_config)
    end.to output(/CSP header already set/).to_stderr

    expect(response.headers['content-security-policy']).to include("'nonce-abc123'")
  end

  it 'uses development directives when development_mode is set' do
    response.send_csp_headers('text/html', 'devnonce',
      security_config: nonce_config, development_mode: true)

    csp = response.headers['content-security-policy']
    # Development allows inline scripts alongside the nonce; production does not.
    expect(csp).to include("script-src 'nonce-devnonce' 'unsafe-inline'")
  end

  # The apply is delegated to the shared core (Config#write_nonce_csp), whose
  # guards now also protect this helper: no policy is emitted for a blank nonce
  # (previously a broken 'nonce-' policy) or a non-HTML content type.
  describe 'shared-core guards (delano/otto#179)' do
    it 'does not emit a broken policy for a nil nonce' do
      response.send_csp_headers('text/html', nil, security_config: nonce_config)

      expect(response.headers).not_to have_key('content-security-policy')
    end

    it 'does not emit a broken policy for an empty nonce' do
      response.send_csp_headers('text/html', '', security_config: nonce_config)

      expect(response.headers).not_to have_key('content-security-policy')
    end

    it 'does not emit a CSP for a non-HTML content type' do
      response.send_csp_headers('application/json', 'abc123', security_config: nonce_config)

      expect(response.headers['content-type']).to eq('application/json')
      expect(response.headers).not_to have_key('content-security-policy')
    end
  end
end
