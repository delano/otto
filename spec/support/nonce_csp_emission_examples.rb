# spec/support/nonce_csp_emission_examples.rb
#
# frozen_string_literal: true

# Contract-spec suites shared by the in-framework nonce-CSP emission surfaces
# that opt in: the Writer core, the EmitMiddleware, and Otto::Response#apply_csp.
# (The deprecated Otto::Response#send_csp_headers inherits the same contract by
# delegating to #apply_csp, so it is exercised transitively rather than via these
# suites.) Running the same guards, casing, and no-duplicate assertions against
# each surface is what keeps the emission invariants from drifting apart again —
# the whole point of routing every surface through one apply core.
#
# A host example group opts in by:
#   include_examples 'a nonce-CSP emission surface'
# and defining an `emit_csp` helper with this contract:
#
#   emit_csp(headers:, nonce:, mode: <surface default>, enabled: true,
#            development_mode: false) -> Hash  # the resulting response headers
#
# The helper drives the surface under test and returns the response headers as
# the surface left them, so the shared examples can assert on observable state.
# `headers` may be pre-populated (e.g. with a case-variant CSP key) to exercise
# the casing/clobber matrix.

RSpec.shared_examples 'a nonce-CSP emission surface' do
  # A distinctive nonce so "the header carries THIS request's nonce" is
  # unambiguous (env-nonce / header agreement).
  let(:test_nonce) { 'contract-nonce-Xyz09+/' }

  def csp_keys(headers)
    headers.keys.select { |k| k.to_s.casecmp?('content-security-policy') }
  end

  def csp_value(headers)
    key = csp_keys(headers).first
    key && headers[key]
  end

  context 'on the happy path (enabled, HTML, nonce present, no existing CSP)' do
    let(:result_headers) do
      emit_csp(headers: { 'content-type' => 'text/html; charset=utf-8' }, nonce: test_nonce)
    end

    it 'writes exactly one CSP header (no duplicate case-variant keys)' do
      expect(csp_keys(result_headers).length).to eq(1)
    end

    it 'writes the canonical lowercase key' do
      expect(csp_keys(result_headers)).to eq(['content-security-policy'])
    end

    it "carries this request's nonce (view/header agreement)" do
      expect(csp_value(result_headers)).to include("'nonce-#{test_nonce}'")
    end
  end

  context 'guards' do
    it 'skips when nonce-CSP is disabled' do
      headers = emit_csp(headers: { 'content-type' => 'text/html' }, nonce: test_nonce, enabled: false)
      expect(csp_keys(headers)).to be_empty
    end

    it 'skips when the nonce is blank' do
      headers = emit_csp(headers: { 'content-type' => 'text/html' }, nonce: '')
      expect(csp_keys(headers)).to be_empty
    end

    it 'skips when the nonce is nil' do
      headers = emit_csp(headers: { 'content-type' => 'text/html' }, nonce: nil)
      expect(csp_keys(headers)).to be_empty
    end

    it 'skips a non-HTML (JSON) response' do
      headers = emit_csp(headers: { 'content-type' => 'application/json' }, nonce: test_nonce)
      expect(csp_keys(headers)).to be_empty
    end

    it 'skips a response with no Content-Type' do
      headers = emit_csp(headers: {}, nonce: test_nonce)
      expect(csp_keys(headers)).to be_empty
    end

    it 'emits for text/html with charset and other parameters' do
      headers = emit_csp(headers: { 'content-type' => 'text/html; charset=utf-8' }, nonce: test_nonce)
      expect(csp_keys(headers)).not_to be_empty
    end

    it 'emits for an uppercase TEXT/HTML media type (case-insensitive)' do
      headers = emit_csp(headers: { 'content-type' => 'TEXT/HTML' }, nonce: test_nonce)
      expect(csp_keys(headers)).not_to be_empty
    end

    it 'skips a media type that merely starts with text/html (e.g. text/html5)' do
      headers = emit_csp(headers: { 'content-type' => 'text/html5' }, nonce: test_nonce)
      expect(csp_keys(headers)).to be_empty
    end
  end

  context 'development mode' do
    it 'uses the development directive set when requested' do
      headers = emit_csp(headers: { 'content-type' => 'text/html' }, nonce: test_nonce, development_mode: true)
      expect(csp_value(headers)).to include("script-src 'nonce-#{test_nonce}' 'unsafe-inline'")
    end
  end
end

# Override-mode surfaces (a deliberate per-request call). These REPLACE an
# existing CSP and normalize the key to canonical lowercase.
RSpec.shared_examples 'a CSP override surface' do
  let(:test_nonce) { 'override-nonce-42' }

  def override_csp_keys(headers)
    headers.keys.select { |k| k.to_s.casecmp?('content-security-policy') }
  end

  it 'replaces an existing lowercase CSP' do
    headers = emit_csp(
      headers: { 'content-type' => 'text/html', 'content-security-policy' => "default-src 'self'" },
      nonce: test_nonce, mode: :override
    )
    expect(override_csp_keys(headers).length).to eq(1)
    expect(headers['content-security-policy']).to include("'nonce-#{test_nonce}'")
  end

  it 'normalizes a mixed-case CSP key to a single lowercase key' do
    headers = emit_csp(
      headers: { 'content-type' => 'text/html', 'Content-Security-Policy' => "default-src 'self'" },
      nonce: test_nonce, mode: :override
    )
    expect(override_csp_keys(headers)).to eq(['content-security-policy'])
    expect(headers['content-security-policy']).to include("'nonce-#{test_nonce}'")
  end

  it 'collapses duplicate case-variant keys into one lowercase key' do
    headers = emit_csp(
      headers: {
        'content-type' => 'text/html',
        'Content-Security-Policy' => 'OLD-A',
        'content-security-policy' => 'OLD-B',
      },
      nonce: test_nonce, mode: :override
    )
    expect(override_csp_keys(headers)).to eq(['content-security-policy'])
    expect(headers['content-security-policy']).to include("'nonce-#{test_nonce}'")
  end
end

# Backstop-mode surfaces (a passive layer). These DEFER to any existing CSP,
# regardless of the key's casing — the case-insensitive detection is what fixes
# the reviewer-flagged case-sensitive lookups against canonical-cased headers.
RSpec.shared_examples 'a CSP backstop surface' do
  let(:test_nonce) { 'backstop-nonce-7' }

  def csp_entries(headers)
    headers.select { |k, _| k.to_s.casecmp?('content-security-policy') }
  end

  # Assert on VALUE preservation + single entry rather than the exact key
  # string, so the suite is surface-independent: raw-tuple surfaces (Writer,
  # middleware) preserve the caller's key casing, while Rack::Headers-backed
  # surfaces (Response) auto-lowercase on insertion. Either way, a case-SENSITIVE
  # bug would fail to detect the existing CSP and leave a second entry (or a
  # changed value) — which these assertions catch.
  it 'defers to an existing lowercase CSP (leaves it untouched)' do
    headers = emit_csp(
      headers: { 'content-type' => 'text/html', 'content-security-policy' => 'PRESET' },
      nonce: test_nonce, mode: :backstop
    )
    expect(csp_entries(headers).values).to eq(['PRESET'])
  end

  it 'defers to an existing MIXED-CASE CSP (case-insensitive; leaves it untouched)' do
    headers = emit_csp(
      headers: { 'content-type' => 'text/html', 'Content-Security-Policy' => 'PRESET' },
      nonce: test_nonce, mode: :backstop
    )
    entries = csp_entries(headers)
    expect(entries.values).to eq(['PRESET'])
    expect(entries.size).to eq(1)
  end

  it 'fills the gap when no CSP is present' do
    headers = emit_csp(
      headers: { 'content-type' => 'text/html' },
      nonce: test_nonce, mode: :backstop
    )
    expect(headers['content-security-policy']).to include("'nonce-#{test_nonce}'")
  end
end
