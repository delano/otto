# spec/otto/ip_harmonization_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Coverage for the IP/trusted-proxy resolution harmonization described in
# OTS issue onetimesecret#3436 (upstream dependency on otto#58):
#   1. Proper IPAddr CIDR matching in Security::Config#trusted_proxy?
#   2. Resolve-once canonical env['otto.client_ip'] (resolve/mask split)
#   3. IPPrivacyMiddleware idempotency (order-safe when mounted twice)
#   4. IPv6-safe validate_ip_address (no more split(':') truncation)
RSpec.describe 'IP resolution harmonization (otto#58 / OTS#3436)' do
  let(:app) { ->(_env) { [200, {}, ['OK']] } }

  describe Otto::Security::Config, '#trusted_proxy? CIDR matching' do
    let(:config) { described_class.new }

    it 'matches IPv4 addresses inside a CIDR range' do
      config.add_trusted_proxy('10.0.0.0/8')

      expect(config.trusted_proxy?('10.1.2.3')).to be true
      expect(config.trusted_proxy?('10.255.255.254')).to be true
      expect(config.trusted_proxy?('11.0.0.1')).to be false
    end

    it 'matches a bare host only exactly (no textual-prefix false positives)' do
      config.add_trusted_proxy('203.0.113.7')

      expect(config.trusted_proxy?('203.0.113.7')).to be true
      expect(config.trusted_proxy?('203.0.113.70')).to be false
    end

    it 'matches IPv6 addresses inside a CIDR range' do
      config.add_trusted_proxy('2001:db8::/32')

      expect(config.trusted_proxy?('2001:db8:abcd::1')).to be true
      expect(config.trusted_proxy?('2001:dead::1')).to be false
    end

    it 'matches a bare IPv6 host only exactly' do
      config.add_trusted_proxy('2001:db8::1')

      expect(config.trusted_proxy?('2001:db8::1')).to be true
      expect(config.trusted_proxy?('2001:db8::2')).to be false
    end

    it 'matches an IPv4-mapped IPv6 peer against an IPv4 range (dual-stack)' do
      config.add_trusted_proxy('10.0.0.0/8')

      expect(config.trusted_proxy?('::ffff:10.0.0.1')).to be true
      expect(config.trusted_proxy?('::ffff:11.0.0.1')).to be false
    end

    it 'does not match across address families' do
      config.add_trusted_proxy('10.0.0.0/8')

      expect(config.trusted_proxy?('::1')).to be false
    end

    it 'returns false for malformed / blank query values instead of raising' do
      config.add_trusted_proxy('10.0.0.0/8')

      expect(config.trusted_proxy?('not-an-ip')).to be false
      expect(config.trusted_proxy?('')).to be false
      expect(config.trusted_proxy?(nil)).to be false
    end

    it 'still supports Regexp and non-IP prefix entries' do
      config.add_trusted_proxy(/\A192\.168\./)
      config.add_trusted_proxy('172.16.')

      expect(config.trusted_proxy?('192.168.5.5')).to be true
      expect(config.trusted_proxy?('172.16.9.9')).to be true
      expect(config.trusted_proxy?('10.0.0.1')).to be false
    end

    it 'parses each string proxy entry once at registration, not per request' do
      allow(IPAddr).to receive(:new).and_call_original

      config.add_trusted_proxy('10.0.0.0/8')
      3.times { config.trusted_proxy?('10.1.2.3') }

      # The proxy entry is parsed once (at registration); only the per-request
      # client IP is parsed on each call.
      expect(IPAddr).to have_received(:new).with('10.0.0.0/8').once
    end

    it 'still matches correctly after the config is deep-frozen' do
      config.add_trusted_proxy('10.0.0.0/8')
      config.deep_freeze!

      expect(config.trusted_proxy?('10.1.2.3')).to be true
      expect(config.trusted_proxy?('11.0.0.1')).to be false
    end
  end

  describe Otto::Security::Middleware::IPPrivacyMiddleware do
    let(:security_config) { Otto::Security::Config.new }
    let(:middleware) { described_class.new(app, security_config) }

    describe "canonical env['otto.client_ip']" do
      it 'is the masked IP for a public direct connection' do
        env = { 'REMOTE_ADDR' => '203.0.113.50' }
        middleware.call(env)

        expect(env['otto.client_ip']).to eq('203.0.113.0')
        expect(env['otto.client_ip']).to eq(env['REMOTE_ADDR'])
      end

      it 'is the real (unmasked) IP for an exempt private connection' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['otto.client_ip']).to eq('192.168.1.100')
      end

      it 'is the resolved real IP when privacy is disabled' do
        security_config.ip_privacy_config.disable!
        env = { 'REMOTE_ADDR' => '203.0.113.50' }
        described_class.new(app, security_config).call(env)

        expect(env['otto.client_ip']).to eq('203.0.113.50')
      end

      it 'resolves the client (not the proxy) behind a trusted proxy' do
        security_config.add_trusted_proxy('10.0.0.1')
        env = {
          'REMOTE_ADDR' => '10.0.0.1',
          'HTTP_X_FORWARDED_FOR' => '203.0.113.50',
        }
        middleware.call(env)

        expect(env['otto.client_ip']).to eq('203.0.113.0')
      end
    end

    describe 'idempotency' do
      it 'a second pass with a different config does not re-resolve or re-mask' do
        env = { 'REMOTE_ADDR' => '203.0.113.50' }

        # First pass: mask 1 octet -> 203.0.113.0
        described_class.new(app, security_config).call(env)
        expect(env['otto.client_ip']).to eq('203.0.113.0')

        # A 2-octet config would yield 203.0.0.0 if it ran; the idempotency
        # guard must prevent the second pass from touching anything.
        cfg2 = Otto::Security::Config.new
        cfg2.ip_privacy_config.octet_precision = 2
        described_class.new(app, cfg2).call(env)

        expect(env['otto.client_ip']).to eq('203.0.113.0')
        expect(env['REMOTE_ADDR']).to eq('203.0.113.0')
      end

      it 'is order-safe when two instances are stacked' do
        security_config.add_trusted_proxy('10.0.0.1')
        inner = described_class.new(app, security_config)
        outer = described_class.new(inner, security_config)

        env = {
          'REMOTE_ADDR' => '10.0.0.1',
          'HTTP_X_FORWARDED_FOR' => '203.0.113.50',
        }
        outer.call(env)

        expect(env['otto.client_ip']).to eq('203.0.113.0')
        expect(env['REMOTE_ADDR']).to eq('203.0.113.0')
        expect(env['HTTP_X_FORWARDED_FOR']).to eq('203.0.113.0')
      end
    end

    describe 'IPv6 proxy resolution' do
      before { security_config.add_trusted_proxy('2001:db8::/32') }

      it 'resolves and masks an IPv6 client behind a trusted IPv6 proxy' do
        env = {
          'REMOTE_ADDR' => '2001:db8::1',                  # trusted proxy
          'HTTP_X_FORWARDED_FOR' => '2606:4700:4700::1111', # real client
        }
        middleware.call(env)

        # Last 80 bits zeroed (octet_precision 1); surfaced canonically.
        expect(env['otto.client_ip']).to eq('2606:4700:4700::')
        expect(env['REMOTE_ADDR']).to eq('2606:4700:4700::')
      end
    end

    describe "canonical env['otto.via_trusted_proxy']" do
      before { security_config.add_trusted_proxy('10.0.0.1') }

      it 'is true when the original peer is a trusted proxy (recorded pre-mask)' do
        env = { 'REMOTE_ADDR' => '10.0.0.1', 'HTTP_X_FORWARDED_FOR' => '203.0.113.50' }
        middleware.call(env)

        expect(env['otto.via_trusted_proxy']).to be true
        # REMOTE_ADDR was masked to the client, but the trust flag is preserved
        expect(env['REMOTE_ADDR']).to eq('203.0.113.0')
      end

      it 'is false when the connecting peer is not a trusted proxy' do
        env = { 'REMOTE_ADDR' => '198.51.100.1' }
        middleware.call(env)

        expect(env['otto.via_trusted_proxy']).to be false
      end
    end
  end

  describe Otto::Request, 'canonical reads' do
    def request_for(env_overrides = {})
      env = Rack::MockRequest.env_for('/', env_overrides)
      described_class.new(env)
    end

    it '#ip prefers env[otto.client_ip] when present' do
      req = request_for('REMOTE_ADDR' => '198.51.100.9')
      req.env['otto.client_ip'] = '203.0.113.0'

      expect(req.ip).to eq('203.0.113.0')
    end

    it '#ip falls back to Rack resolution without the middleware' do
      req = request_for('REMOTE_ADDR' => '198.51.100.9')

      expect(req.ip).to eq('198.51.100.9')
    end

    it '#client_ipaddress prefers env[otto.client_ip] when present' do
      req = request_for('REMOTE_ADDR' => '198.51.100.9')
      req.env['otto.client_ip'] = '203.0.113.0'

      expect(req.client_ipaddress).to eq('203.0.113.0')
    end

    it '#client_ipaddress fallback uses the shared resolver behind a trusted proxy' do
      # No middleware ran (otto.client_ip absent), so it must resolve via the
      # same canonical resolver the middleware uses.
      config = Otto::Security::Config.new
      config.add_trusted_proxy('10.0.0.0/8')
      req = request_for('REMOTE_ADDR' => '10.0.0.1', 'HTTP_X_FORWARDED_FOR' => '203.0.113.50')
      allow(req).to receive(:otto_security_config).and_return(config)

      expect(req.client_ipaddress).to eq('203.0.113.50')
    end

    it '#private_ip? is IPv6-aware (delegates to Otto::Utils)' do
      req = request_for

      expect(req.private_ip?('::1')).to be true       # IPv6 loopback
      expect(req.private_ip?('fc00::1')).to be true    # IPv6 ULA
      expect(req.private_ip?('10.0.0.1')).to be true   # IPv4 private
      expect(req.private_ip?('2606:4700:4700::1111')).to be false # public IPv6
    end

    describe '#secure?' do
      it 'is true for a direct HTTPS connection' do
        expect(request_for('SERVER_PORT' => '443').secure?).to be true
        expect(request_for('HTTPS' => 'on').secure?).to be true
      end

      it 'trusts X-Forwarded-Proto when the canonical trust flag is set' do
        req = request_for('REMOTE_ADDR' => '203.0.113.0', 'HTTP_X_FORWARDED_PROTO' => 'https')
        req.env['otto.via_trusted_proxy'] = true

        expect(req.secure?).to be true
      end

      it 'trusts X-Scheme when the canonical trust flag is set' do
        req = request_for('REMOTE_ADDR' => '203.0.113.0', 'HTTP_X_SCHEME' => 'https')
        req.env['otto.via_trusted_proxy'] = true

        expect(req.secure?).to be true
      end

      it 'does not trust forwarded proto when the peer is untrusted' do
        req = request_for('REMOTE_ADDR' => '203.0.113.0', 'HTTP_X_FORWARDED_PROTO' => 'https')
        req.env['otto.via_trusted_proxy'] = false

        expect(req.secure?).to be false
      end

      it 'is not secure for a non-https forwarded proto even via a trusted proxy' do
        req = request_for('REMOTE_ADDR' => '203.0.113.0', 'HTTP_X_FORWARDED_PROTO' => 'http')
        req.env['otto.via_trusted_proxy'] = true

        expect(req.secure?).to be false
      end

      it 'is not secure when forwarded proto is absent even via a trusted proxy' do
        req = request_for('REMOTE_ADDR' => '203.0.113.0')
        req.env['otto.via_trusted_proxy'] = true

        expect(req.secure?).to be false
      end

      it 'does not trust forwarded proto without the middleware or a security config' do
        req = request_for('REMOTE_ADDR' => '10.0.0.1', 'HTTP_X_FORWARDED_PROTO' => 'https')

        expect(req.secure?).to be false
      end
    end

    describe 'privacy helpers read the canonical otto.privacy.* keys' do
      # Regression: these helpers previously read un-namespaced keys
      # (otto.redacted_fingerprint / otto.geo_country / otto.hashed_ip) that the
      # middleware never sets, so they always returned nil.
      def run_privacy(remote_addr)
        env = { 'REMOTE_ADDR' => remote_addr }
        Otto::Security::Middleware::IPPrivacyMiddleware
          .new(app, Otto::Security::Config.new).call(env)
        described_class.new(env)
      end

      it 'populates redacted_fingerprint, masked_ip, hashed_ip and geo_country' do
        req = run_privacy('8.8.8.8') # public IP; geo range -> US

        expect(req.redacted_fingerprint).to be_a(Otto::Privacy::RedactedFingerprint)
        expect(req.masked_ip).to eq('8.8.8.0')
        expect(req.hashed_ip).to match(/\A[0-9a-f]{64}\z/)
        expect(req.geo_country).to eq('US')
      end

      it 'returns nil from redacted_fingerprint/hashed_ip when privacy is disabled' do
        config = Otto::Security::Config.new
        config.ip_privacy_config.disable!
        env = { 'REMOTE_ADDR' => '8.8.8.8' }
        Otto::Security::Middleware::IPPrivacyMiddleware.new(app, config).call(env)
        req = described_class.new(env)

        expect(req.redacted_fingerprint).to be_nil
        expect(req.hashed_ip).to be_nil
      end
    end

    describe '#validate_ip_address (IPv6-safe)' do
      let(:req) { request_for }

      it 'accepts a bare IPv6 address without truncating it' do
        expect(req.send(:validate_ip_address, '2001:db8::1')).to eq('2001:db8::1')
      end

      it 'strips a port from a bracketed IPv6 address' do
        expect(req.send(:validate_ip_address, '[2001:db8::1]:443')).to eq('2001:db8::1')
      end

      it 'strips a port from an IPv4 host:port' do
        expect(req.send(:validate_ip_address, '203.0.113.5:8080')).to eq('203.0.113.5')
      end

      it 'accepts a bare IPv4 address' do
        expect(req.send(:validate_ip_address, '203.0.113.5')).to eq('203.0.113.5')
      end

      it 'rejects malformed input' do
        expect(req.send(:validate_ip_address, 'nope')).to be_nil
        expect(req.send(:validate_ip_address, '')).to be_nil
      end
    end
  end

  describe 'canonical client IP is read everywhere' do
    it 'LoggingHelpers.request_context prefers otto.client_ip, falling back to REMOTE_ADDR' do
      with_canonical = {
        'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/',
        'REMOTE_ADDR' => '10.0.0.1', 'otto.client_ip' => '203.0.113.50'
      }
      without = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/', 'REMOTE_ADDR' => '10.0.0.1' }

      expect(Otto::LoggingHelpers.request_context(with_canonical)[:ip]).to eq('203.0.113.50')
      expect(Otto::LoggingHelpers.request_context(without)[:ip]).to eq('10.0.0.1')
    end

    it 'NoAuthStrategy records the canonical client IP in its metadata' do
      strategy = Otto::Security::Authentication::Strategies::NoAuthStrategy.new

      via_proxy = strategy.authenticate(
        { 'REMOTE_ADDR' => '10.0.0.1', 'otto.client_ip' => '203.0.113.50' }, nil
      )
      direct = strategy.authenticate({ 'REMOTE_ADDR' => '203.0.113.9' }, nil)

      expect(via_proxy.metadata[:ip]).to eq('203.0.113.50')
      expect(direct.metadata[:ip]).to eq('203.0.113.9')
    end
  end
end
