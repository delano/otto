# spec/otto/security/csp/request_extras_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Grammar and shape coverage for the request-scoped CSP extras sanitizer
# (delano/otto#243). Every rejection is drop-and-log, never raise: a hostile
# value must cost the attacker their token, not the response its policy.
RSpec.describe Otto::Security::CSP::RequestExtras do
  before { allow(Otto).to receive(:structured_log) }

  let(:env_key) { described_class::ENV_KEY }

  def from_env_with(value)
    described_class.from_env(described_class::ENV_KEY => value)
  end

  def expect_dropped(reason)
    expect(Otto).to have_received(:structured_log)
      .with(:warn, 'CSP request extra dropped', hash_including(reason: reason))
  end

  def expect_no_drops
    expect(Otto).not_to have_received(:structured_log)
  end

  describe 'env key handling' do
    it 'returns nil (without logging) when the key is absent' do
      expect(described_class.from_env({})).to be_nil
      expect_no_drops
    end

    it 'drops-and-logs a non-Hash value and returns nil' do
      expect(from_env_with('form-action https://a.example.com')).to be_nil
      expect_dropped(:invalid_shape)
    end

    it 'exposes the hardcoded env key as public API' do
      expect(env_key).to eq('otto.csp.extra_directives')
    end
  end

  describe 'directive name normalization' do
    it "treats 'FORM-ACTION', :form_action, and 'form-action' as the same directive" do
      %w[FORM-ACTION form-action].each do |key|
        expect(from_env_with(key => ['https://a.example.com']))
          .to eq('form-action' => ['https://a.example.com'])
      end
      expect(from_env_with(form_action: ['https://a.example.com']))
        .to eq('form-action' => ['https://a.example.com'])
      expect_no_drops
    end

    it 'drops-and-logs a blank key' do
      expect(from_env_with('  ' => ['https://a.example.com'])).to be_nil
      expect_dropped(:invalid_shape)
    end

    it 'merges (unions) token lists when two raw keys normalize to the same directive' do
      result = from_env_with(
        'form_action' => ['https://a.example.com', 'https://both.example.com'],
        'form-action' => ['https://b.example.com', 'https://both.example.com']
      )

      expect(result).to eq(
        'form-action' => ['https://a.example.com', 'https://both.example.com', 'https://b.example.com']
      )
      expect_no_drops # nothing was dropped, so nothing is logged
    end
  end

  describe 'refused directives' do
    described_class::REFUSED_DIRECTIVES.each do |name|
      it "refuses #{name} wholesale (drop-and-log)" do
        expect(from_env_with(name => ['https://a.example.com'])).to be_nil
        expect_dropped(:refused_directive)
      end
    end

    it 'refuses a refused directive addressed via a Symbol key' do
      expect(from_env_with(script_src: ['https://a.example.com'])).to be_nil
      expect_dropped(:refused_directive)
    end

    it 'refuses a valueless directive addressed via a Symbol/underscore key' do
      expect(from_env_with(upgrade_insecure_requests: ['https://a.example.com'])).to be_nil
      expect_dropped(:refused_directive)
    end
  end

  describe 'token grammar — accepted origins' do
    {
      'a plain https origin' => ['https://idp.example.com', 'https://idp.example.com'],
      'a plain http origin' => ['http://idp.example.com', 'http://idp.example.com'],
      'a non-default port (kept)' => ['https://idp.example.com:8443', 'https://idp.example.com:8443'],
      'a default port (omitted)' => ['https://idp.example.com:443', 'https://idp.example.com'],
      'an uppercase origin (downcased)' => ['HTTPS://IDP.EXAMPLE.COM', 'https://idp.example.com'],
      'an IDN host in punycode form' => ['https://xn--mnchen-3ya.example', 'https://xn--mnchen-3ya.example'],
      'a single trailing dot (FQDN root form, stripped)' => ['https://idp.example.com.', 'https://idp.example.com'],
      'the highest valid port' => ['https://idp.example.com:65535', 'https://idp.example.com:65535'],
      # URI::Generic#host retains the brackets for IPv6 literals ('[2001:db8::1]',
      # not '2001:db8::1') — exactly what a CSP host-source needs. Pinned here so
      # a future refactor to uri.hostname (which strips them) fails loudly.
      'an IPv6 literal (brackets retained)' => ['https://[2001:db8::1]', 'https://[2001:db8::1]'],
      'an IPv6 literal with a port (downcased, port kept)' =>
        ['https://[2001:DB8::1]:8443', 'https://[2001:db8::1]:8443'],
    }.each do |label, (token, normalized)|
      it "accepts #{label}" do
        expect(from_env_with('form-action' => [token])).to eq('form-action' => [normalized])
        expect_no_drops
      end
    end

    it 'accepts a String value as a whitespace-separated source list' do
      expect(from_env_with('form-action' => 'https://a.example.com https://b.example.com'))
        .to eq('form-action' => ['https://a.example.com', 'https://b.example.com'])
    end

    it 'deduplicates tokens that normalize to the same origin' do
      expect(from_env_with('form-action' => ['https://a.example.com', 'HTTPS://A.EXAMPLE.COM:443']))
        .to eq('form-action' => ['https://a.example.com'])
    end
  end

  describe 'token grammar — rejected tokens (drop-and-log, keep the rest)' do
    [
      ["the 'self' keyword", "'self'"],
      ["the 'unsafe-inline' keyword", "'unsafe-inline'"],
      ["the 'none' keyword", "'none'"],
      ['the data: scheme source', 'data:'],
      ['the blob: scheme source', 'blob:'],
      ['the bare https: scheme source', 'https:'],
      ['a bare wildcard', '*'],
      ['a wildcard host', 'https://*.example.com'],
      ['a path suffix', 'https://idp.example.com/login'],
      ['a path suffix on an IPv6 literal', 'https://[2001:db8::1]/path'],
      ['a bare trailing slash (still a path)', 'https://idp.example.com/'],
      ['userinfo', 'https://user:secret@idp.example.com'],
      ['a query string', 'https://idp.example.com?next=x'],
      ['a fragment', 'https://idp.example.com#top'],
      ['embedded whitespace', 'https://idp.example .com'],
      ['a semicolon (directive injection)', 'https://idp.example.com;script-src *'],
      ['a carriage return', "https://idp.example.com\rx"],
      ['a newline (header injection)', "https://idp.example.com\nscript-src *"],
      ['a non-http(s) scheme', 'ftp://idp.example.com'],
      ['a schemeless host', 'idp.example.com'],
      ['an empty string', ''],
      ['a doubled trailing dot (only ONE root dot is stripped)', 'https://idp.example.com..'],
      ['a percent-encoding in the host (URI passes it through literally)', 'http://idp.example.com%00'],
      ['a port beyond the TCP range', 'http://idp.example.com:99999999999999999999999'],
      ['port zero', 'http://idp.example.com:0'],
    ].each do |label, token|
      it "rejects #{label}" do
        expect(from_env_with('form-action' => [token])).to be_nil
        expect_dropped(:not_an_origin)
      end
    end

    it 'rejects a non-String token element' do
      expect(from_env_with('form-action' => [42])).to be_nil
      expect_dropped(:invalid_shape)
    end

    it 'drops-and-logs a value that is neither String nor Array' do
      expect(from_env_with('form-action' => 42)).to be_nil
      expect_dropped(:invalid_shape)
    end

    it 'returns nil (not an empty hash) when everything was dropped' do
      expect(from_env_with('form-action' => ['*'], 'connect-src' => ["'self'"])).to be_nil
    end

    it 'keeps the surviving tokens when only some are rejected' do
      result = from_env_with('form-action' => ["'unsafe-inline'", 'https://ok.example.com', '*'])

      expect(result).to eq('form-action' => ['https://ok.example.com'])
      expect(Otto).to have_received(:structured_log)
        .with(:warn, 'CSP request extra dropped', hash_including(reason: :not_an_origin))
        .twice
    end

    it 'keeps other directives when one key is refused' do
      result = from_env_with(
        'script-src' => ['https://cdn.example.com'],
        'form-action' => ['https://idp.example.com']
      )
      expect(result).to eq('form-action' => ['https://idp.example.com'])
      expect_dropped(:refused_directive)
    end
  end

  describe 'log payload' do
    it 'includes the directive, a truncated token inspect, and request context' do
      env = mock_rack_env(method: 'POST', path: '/signin')
      env[env_key] = { 'form-action' => ['*'] }

      described_class.from_env(env)

      expect(Otto).to have_received(:structured_log).with(
        :warn, 'CSP request extra dropped',
        hash_including(directive: 'form-action', token: '"*"', reason: :not_an_origin,
                       method: 'POST', path: '/signin')
      )
    end

    it 'truncates a long token to 128 characters of inspect output' do
      long = "https://#{'a' * 300}.example.com/evil"

      from_env_with('form-action' => [long])

      expect(Otto).to have_received(:structured_log) do |_level, _msg, data|
        expect(data[:token].length).to be <= 128
      end
    end
  end
end
