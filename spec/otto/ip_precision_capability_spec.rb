# spec/otto/ip_precision_capability_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# The two-axis privacy design:
# - Observability posture (what persists in env/logs) — named profiles.
# - Policy precision (what a decision may examine, ephemerally) — the
#   verdict-only env['otto.ip_match'] capability and its Utils primitive.
RSpec.describe 'IP precision capability and privacy profiles' do
  describe 'Otto::Utils.ip_in_cidrs?' do
    it 'matches an IPv4 host inside a CIDR range' do
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', ['203.0.113.0/24'])).to be true
    end

    it 'matches a full /32 host entry' do
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', ['203.0.113.7/32'])).to be true
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.8', ['203.0.113.7/32'])).to be false
    end

    it 'matches IPv6 ranges' do
      expect(Otto::Utils.ip_in_cidrs?('2001:db8:85a3::1', ['2001:db8::/32'])).to be true
      expect(Otto::Utils.ip_in_cidrs?('2001:db9::1', ['2001:db8::/32'])).to be false
    end

    it 'folds IPv4-mapped IPv6 clients onto IPv4 ranges' do
      expect(Otto::Utils.ip_in_cidrs?('::ffff:203.0.113.7', ['203.0.113.0/24'])).to be true
    end

    it 'skips ranges of the other address family instead of raising' do
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', ['2001:db8::/32'])).to be false
      expect(Otto::Utils.ip_in_cidrs?('2001:db8::1', ['203.0.113.0/24'])).to be false
    end

    it 'accepts pre-parsed IPAddr entries' do
      ranges = [IPAddr.new('203.0.113.0/24'), IPAddr.new('2001:db8::/32')]
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', ranges)).to be true
      expect(Otto::Utils.ip_in_cidrs?('2001:db8::1', ranges)).to be true
    end

    it 'accepts an IPAddr as the client address' do
      expect(Otto::Utils.ip_in_cidrs?(IPAddr.new('203.0.113.7'), ['203.0.113.0/24'])).to be true
    end

    it 'strips a port from the client address' do
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7:443', ['203.0.113.0/24'])).to be true
      expect(Otto::Utils.ip_in_cidrs?('[2001:db8::1]:443', ['2001:db8::/32'])).to be true
    end

    it 'fails closed on nil, blank, or malformed client input' do
      expect(Otto::Utils.ip_in_cidrs?(nil, ['203.0.113.0/24'])).to be false
      expect(Otto::Utils.ip_in_cidrs?('', ['203.0.113.0/24'])).to be false
      expect(Otto::Utils.ip_in_cidrs?('not-an-ip', ['203.0.113.0/24'])).to be false
    end

    it 'returns false for nil or empty range lists' do
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', nil)).to be false
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', [])).to be false
    end

    it 'raises for an invalid CIDR entry (configuration error, not runtime data)' do
      expect do
        Otto::Utils.ip_in_cidrs?('203.0.113.7', ['not-a-cidr'])
      end.to raise_error(IPAddr::InvalidAddressError)
    end
  end

  describe 'privacy profiles' do
    describe Otto::Privacy::Config do
      it 'defaults to the :masked profile' do
        expect(described_class.new.profile).to eq(:masked)
      end

      it 'applies :anonymous presets' do
        config = described_class.new
        config.profile = :anonymous
        expect(config.enabled?).to be true
        expect(config.mask_private_ips).to be true
        expect(config.profile).to eq(:anonymous)
      end

      it 'applies :audit presets' do
        config = described_class.new
        config.profile = :audit
        expect(config.disabled?).to be true
        expect(config.profile).to eq(:audit)
      end

      it 'returns to :masked when re-applied' do
        config = described_class.new
        config.profile = :audit
        config.profile = :masked
        expect(config.enabled?).to be true
        expect(config.mask_private_ips).to be false
        expect(config.profile).to eq(:masked)
      end

      it 'derives the profile from live knob state, never a stale label' do
        config = described_class.new
        config.profile = :masked
        config.mask_private_ips = true
        expect(config.profile).to eq(:anonymous)
      end

      it 'raises on an unknown profile name' do
        expect { described_class.new.profile = :stealth }
          .to raise_error(ArgumentError, /Unknown privacy profile/)
      end

      it 'accepts profile: at construction, with explicit options overriding the preset' do
        config = described_class.new(profile: :anonymous, mask_private_ips: false)
        expect(config.mask_private_ips).to be false
        expect(config.enabled?).to be true
      end

      it 'leaves non-profile knobs untouched when a profile is applied' do
        config = described_class.new(octet_precision: 2)
        config.profile = :audit
        expect(config.octet_precision).to eq(2)
      end
    end

    describe 'Otto#configure_ip_privacy(profile:)' do
      it 'applies the profile to the security config' do
        otto = Otto.new
        otto.configure_ip_privacy(profile: :audit)
        expect(otto.security_config.ip_privacy_config.profile).to eq(:audit)
      end

      it 'lets explicit options in the same call override the preset' do
        otto = Otto.new
        otto.configure_ip_privacy(profile: :audit)
        otto.configure_ip_privacy(profile: :masked, octet_precision: 2)
        config = otto.security_config.ip_privacy_config
        expect(config.profile).to eq(:masked)
        expect(config.octet_precision).to eq(2)
      end

      it 'raises on an unknown profile' do
        otto = Otto.new
        expect { otto.configure_ip_privacy(profile: :bogus) }
          .to raise_error(ArgumentError, /Unknown privacy profile/)
      end
    end
  end

  describe "env['otto.ip_match'] capability" do
    let(:app) { ->(env) { [200, {}, ['OK']] } }
    let(:security_config) { Otto::Security::Config.new }
    let(:middleware) { Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config) }

    context 'masked path (public IP, privacy enabled)' do
      it 'matches the full unmasked address while otto.client_ip is masked' do
        env = { 'REMOTE_ADDR' => '203.0.113.7' }
        middleware.call(env)

        expect(env['otto.client_ip']).to eq('203.0.113.0')
        expect(env['otto.ip_match'].call(['203.0.113.7/32'])).to be true
        expect(env['otto.ip_match'].call(['203.0.113.8/32'])).to be false
      end

      it 'gives /32 precision the masked client_ip cannot express' do
        env = { 'REMOTE_ADDR' => '203.0.113.7' }
        middleware.call(env)

        # The masked IP would wrongly match a sibling host's /32; the
        # capability does not.
        expect(Otto::Utils.ip_in_cidrs?(env['otto.client_ip'], ['203.0.113.0/32'])).to be true
        expect(env['otto.ip_match'].call(['203.0.113.0/32'])).to be false
      end

      it 'does not place the unmasked address anywhere in env' do
        env = { 'REMOTE_ADDR' => '203.0.113.7' }
        middleware.call(env)

        serializable = env.reject { |_k, v| v.is_a?(Proc) || v.is_a?(Otto::Privacy::RedactedFingerprint) }
        expect(serializable.inspect).not_to include('203.0.113.7')
      end

      it 'matches IPv6 clients at full /128 precision' do
        env = { 'REMOTE_ADDR' => '2001:db8:85a3::8a2e:370:7334' }
        middleware.call(env)

        expect(env['otto.ip_match'].call(['2001:db8:85a3::8a2e:370:7334/128'])).to be true
        expect(env['otto.ip_match'].call(['2001:db8:85a3::8a2e:370:7335/128'])).to be false
      end

      it 'resolves through a trusted proxy before matching' do
        security_config.add_trusted_proxy('10.0.0.0/8')
        env = { 'REMOTE_ADDR' => '10.0.0.1', 'HTTP_X_FORWARDED_FOR' => '203.0.113.7' }
        middleware.call(env)

        expect(env['otto.ip_match'].call(['203.0.113.7/32'])).to be true
      end
    end

    context 'private-exempt path' do
      it 'installs the capability for exempt private IPs' do
        env = { 'REMOTE_ADDR' => '192.168.1.50' }
        middleware.call(env)

        expect(env['otto.client_ip']).to eq('192.168.1.50')
        expect(env['otto.ip_match'].call(['192.168.1.50/32'])).to be true
        expect(env['otto.ip_match'].call(['192.168.2.0/24'])).to be false
      end
    end

    context 'privacy disabled (:audit profile)' do
      it 'installs the same capability for interface consistency' do
        security_config.ip_privacy_config.profile = :audit
        env = { 'REMOTE_ADDR' => '203.0.113.7' }
        middleware.call(env)

        expect(env['otto.client_ip']).to eq('203.0.113.7')
        expect(env['otto.ip_match'].call(['203.0.113.7/32'])).to be true
      end
    end

    context 'no resolvable client IP' do
      it 'fails closed: the capability returns false for any range' do
        env = {}
        middleware.call(env)

        expect(env['otto.ip_match']).to be_a(Proc)
        expect(env['otto.ip_match'].call(['0.0.0.0/0', '::/0'])).to be false
      end
    end

    context 'idempotency guard' do
      it 'does not install a second capability when otto.client_ip is pre-set' do
        env = { 'REMOTE_ADDR' => '203.0.113.7', 'otto.client_ip' => '203.0.113.0' }
        middleware.call(env)

        expect(env['otto.ip_match']).to be_nil
      end
    end

    it 'raises for invalid CIDR entries (configuration error surfaces to the caller)' do
      env = { 'REMOTE_ADDR' => '203.0.113.7' }
      middleware.call(env)

      expect { env['otto.ip_match'].call(['bogus']) }.to raise_error(IPAddr::InvalidAddressError)
    end
  end
end
