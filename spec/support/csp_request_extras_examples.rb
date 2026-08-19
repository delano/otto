# spec/support/csp_request_extras_examples.rb
#
# frozen_string_literal: true

# Contract-spec suite for the request-scoped CSP directive extras channel
# (env['otto.csp.extra_directives'], delano/otto#243), shared by the surfaces
# that can see a Rack env: the Writer core (env: kwarg), the EmitMiddleware
# (its own env), and Otto::Response#apply_csp (request&.env). A SEPARATE group
# from 'a nonce-CSP emission surface' on purpose — that group's emit_csp
# helper contract stays untouched.
#
# A host example group opts in by:
#   include_examples 'a request-extras-aware CSP surface'
# and defining an `emit_csp_with_env` helper with this contract:
#
#   emit_csp_with_env(headers:, nonce:, env:, extras_enabled: true) -> Hash
#     # resulting response headers
#
# The env is the hash the surface will read extras from; the helper wires it
# however the surface requires (Writer kwarg, middleware env, wired request).
# `extras_enabled: false` must build the config WITHOUT
# `enable_csp_request_extras!` — the channel is boot-time opt-in, and every
# surface must ignore the env key entirely when it is off.

RSpec.shared_examples 'a request-extras-aware CSP surface' do
  let(:extras_nonce) { 'extras-nonce-3+/' }
  let(:extras_html) { { 'content-type' => 'text/html; charset=utf-8' } }

  def extras_baseline_policy
    emit_csp_with_env(headers: extras_html.dup, nonce: extras_nonce, env: {})['content-security-policy']
  end

  it 'widens the named directive with a request-scoped extra origin (this request only)' do
    env = { 'otto.csp.extra_directives' => { 'form-action' => ['https://idp.example.com'] } }
    headers = emit_csp_with_env(headers: extras_html.dup, nonce: extras_nonce, env: env)

    expect(headers['content-security-policy'])
      .to include("form-action 'self' https://idp.example.com;")
  end

  it 'ignores env extras entirely when the channel is not enabled (the default)' do
    allow(Otto).to receive(:structured_log)
    env = { 'otto.csp.extra_directives' => { 'form-action' => ['https://idp.example.com'] } }
    headers = emit_csp_with_env(headers: extras_html.dup, nonce: extras_nonce, env: env,
                                extras_enabled: false)

    expect(headers['content-security-policy']).to eq(extras_baseline_policy)
    expect(headers['content-security-policy']).not_to include('idp.example.com')
    # Disabled means the channel does not exist: no sanitize work, no logs.
    expect(Otto).not_to have_received(:structured_log)
  end

  it 'emits the base policy byte-identically for a request without extras' do
    headers = emit_csp_with_env(headers: extras_html.dup, nonce: extras_nonce, env: {})
    expect(headers['content-security-policy']).to eq(extras_baseline_policy)
    expect(headers['content-security-policy']).not_to include('idp.example.com')
  end

  it 'drops hostile extras (logged, never raised) and leaves the policy byte-identical' do
    allow(Otto).to receive(:structured_log)
    env = {
      'otto.csp.extra_directives' => {
        'form-action' => ["'unsafe-inline'", '*', 'https://idp.example.com;script-src *', "https://x\n.com"],
        'script-src' => ['https://cdn.example.com'],
      },
    }
    headers = emit_csp_with_env(headers: extras_html.dup, nonce: extras_nonce, env: env)

    expect(headers['content-security-policy']).to eq(extras_baseline_policy)
    expect(Otto).to have_received(:structured_log)
      .with(:warn, 'CSP request extra dropped', hash_including(reason: :not_an_origin))
      .at_least(:once)
    expect(Otto).to have_received(:structured_log)
      .with(:warn, 'CSP request extra dropped', hash_including(reason: :refused_directive))
  end
end
