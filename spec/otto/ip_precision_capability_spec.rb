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

    it 'folds IPv4-mapped IPv6 ranges onto IPv4 clients (symmetric with the client fold)' do
      expect(Otto::Utils.ip_in_cidrs?('10.1.2.3', ['::ffff:10.0.0.0/104'])).to be true
      expect(Otto::Utils.ip_in_cidrs?('11.1.2.3', ['::ffff:10.0.0.0/104'])).to be false
      # Host entry, and a mapped client against a mapped range.
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', ['::ffff:203.0.113.7/128'])).to be true
      expect(Otto::Utils.ip_in_cidrs?('::ffff:10.1.2.3', ['::ffff:10.0.0.0/104'])).to be true
    end

    it 'leaves genuine IPv6 ranges unfolded' do
      expect(Otto::Utils.ip_in_cidrs?('2001:db8::1', ['2001:db8::/32'])).to be true
      expect(Otto::Utils.ip_in_cidrs?('10.1.2.3', ['2001:db8::/32'])).to be false
    end

    it 'accepts pre-parsed IPAddr entries' do
      ranges = [IPAddr.new('203.0.113.0/24'), IPAddr.new('2001:db8::/32')]
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', ranges)).to be true
      expect(Otto::Utils.ip_in_cidrs?('2001:db8::1', ranges)).to be true
    end

    it 'folds frozen pre-parsed entries without raising' do
      # IPAddr#native builds its result with #clone, which carries frozen state
      # over; a caller freezing their range config must not hit FrozenError.
      frozen_mapped = IPAddr.new('::ffff:10.0.0.0/104').freeze
      frozen_plain = IPAddr.new('10.0.0.0/8').freeze

      expect(Otto::Utils.ip_in_cidrs?('10.1.2.3', [frozen_mapped])).to be true
      expect(Otto::Utils.ip_in_cidrs?('11.1.2.3', [frozen_mapped])).to be false
      expect(Otto::Utils.ip_in_cidrs?('10.1.2.3', [frozen_plain])).to be true
    end

    it 'needs /96 or longer for a mapped range to fold' do
      # Masking at /64 zeroes the ffff marker, so the entry is no longer
      # recognizable as mapped and stays IPv6 — matching neither form.
      expect(Otto::Utils.ip_in_cidrs?('10.1.2.3', ['::ffff:10.0.0.0/64'])).to be false
      expect(Otto::Utils.ip_in_cidrs?('::ffff:10.1.2.3', ['::ffff:10.0.0.0/64'])).to be false
    end

    it 'treats ::ffff:0:0/96 as the whole IPv4 space' do
      expect(Otto::Utils.ip_in_cidrs?('10.1.2.3', ['::ffff:0:0/96'])).to be true
      expect(Otto::Utils.ip_in_cidrs?('203.0.113.7', ['::ffff:0:0/96'])).to be true
      expect(Otto::Utils.ip_in_cidrs?('2001:db8::1', ['::ffff:0:0/96'])).to be false
    end

    it 'does not mutate pre-parsed IPAddr entries while folding' do
      mapped = IPAddr.new('::ffff:10.0.0.0/104')
      ranges = [mapped]

      expect(Otto::Utils.ip_in_cidrs?('10.1.2.3', ranges)).to be true
      expect(Otto::Utils.ip_in_cidrs?('10.1.2.3', ranges)).to be true

      # The caller's configuration array is reusable across requests: still the
      # same object, still IPv6, still mapped.
      expect(ranges.first).to equal(mapped)
      expect(mapped.family).to eq(Socket::AF_INET6)
      expect(mapped.ipv4_mapped?).to be true
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
      # An empty string is fail-closed false as the client IP (runtime data)
      # but raises as a range entry — a blank line or trailing comma in a
      # config file is a configuration error, not an empty allowlist.
      expect do
        Otto::Utils.ip_in_cidrs?('203.0.113.7', [''])
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

      it 'round-trips through all three profiles' do
        # :audit names only `disabled`, so it leaves mask_private_ips set from
        # the :anonymous pass. :masked must re-set both knobs to land clean.
        config = described_class.new
        config.profile = :anonymous
        config.profile = :audit
        expect(config.profile).to eq(:audit)

        config.profile = :masked
        expect(config.enabled?).to be true
        expect(config.mask_private_ips).to be false
        expect(config.profile).to eq(:masked)
      end

      it 'raises ArgumentError, not NoMethodError, for a profile that cannot be a name' do
        # None of Integer, NilClass, or FalseClass responds to #to_sym.
        expect { described_class.new.profile = 123 }
          .to raise_error(ArgumentError, /must be a Symbol or String, got: Integer/)
        expect { described_class.new.profile = nil }
          .to raise_error(ArgumentError, /must be a Symbol or String, got: NilClass/)
        expect { described_class.new(profile: 123) }
          .to raise_error(ArgumentError, /must be a Symbol or String, got: Integer/)
        # false is not "no profile" — only nil means "leave unchanged".
        expect { described_class.new(profile: false) }
          .to raise_error(ArgumentError, /must be a Symbol or String, got: FalseClass/)
      end

      it 'treats profile: nil at construction as "leave unchanged", not an error' do
        # The nil guard at the option site skips the preset entirely, so the
        # nil never reaches profile_presets. Only the setter rejects nil.
        expect(described_class.new(profile: nil).profile).to eq(:masked)
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

      it 'accepts a String profile name wherever a Symbol is accepted' do
        # env/YAML-driven configuration hands profiles over as Strings.
        expect(described_class.new(profile: 'anonymous').profile).to eq(:anonymous)
        config = described_class.new
        config.profile = 'audit'
        expect(config.profile).to eq(:audit)
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

      it 'accepts a String profile name' do
        otto = Otto.new
        otto.configure_ip_privacy(profile: 'audit')
        expect(otto.security_config.ip_privacy_config.profile).to eq(:audit)
      end

      it 'raises on a profile that cannot be a name' do
        otto = Otto.new
        expect { otto.configure_ip_privacy(profile: 123) }
          .to raise_error(ArgumentError, /must be a Symbol or String, got: Integer/)
        expect { otto.configure_ip_privacy(profile: false) }
          .to raise_error(ArgumentError, /must be a Symbol or String, got: FalseClass/)
        # Rejected before any other option is applied.
        expect(otto.security_config.ip_privacy_config.profile).to eq(:masked)
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

      it 'fails closed with no resolvable client IP, same as the privacy-enabled path' do
        security_config.ip_privacy_config.profile = :audit
        env = {}
        middleware.call(env)

        expect(env['otto.ip_match']).to be_a(Proc)
        expect(env['otto.ip_match'].call(['0.0.0.0/0', '::/0'])).to be false
        expect(env['REMOTE_ADDR']).to be_nil
        expect(env['otto.original_ip']).to be_nil
      end
    end

    context ':anonymous profile' do
      it 'masks private IPs that the default profile exempts, without losing precision' do
        security_config.ip_privacy_config.profile = :anonymous
        env = { 'REMOTE_ADDR' => '192.168.1.50' }
        middleware.call(env)

        expect(env['otto.client_ip']).to eq('192.168.1.0')
        expect(env['REMOTE_ADDR']).to eq('192.168.1.0')
        expect(env['otto.original_ip']).to be_nil
        expect(env['otto.ip_match'].call(['192.168.1.50/32'])).to be true
        expect(env['otto.ip_match'].call(['192.168.1.51/32'])).to be false
      end
    end

    context 'debug logging' do
      let(:lines) { [] }
      let(:capturing_logger) do
        Class.new do
          def initialize(sink)
            @sink = sink
          end

          def debug(message = nil)
            @sink << (message || yield).to_s
          end

          def method_missing(_name, *_args) = nil

          def respond_to_missing?(_name, _include_private = false) = true
        end.new(lines)
      end

      # Otto.debug and Otto.logger are process globals; restore both so an
      # enabled spec cannot bleed into the rest of the suite.
      around do |example|
        original_debug  = Otto.debug
        original_logger = Otto.logger
        Otto.debug  = true
        Otto.logger = capturing_logger
        example.run
      ensure
        Otto.debug  = original_debug
        Otto.logger = original_logger
      end

      it 'never writes the unmasked address to the log on the masked path' do
        env = { 'REMOTE_ADDR' => '203.0.113.7' }
        middleware.call(env)

        log = lines.join("\n")
        expect(log).not_to be_empty
        expect(log).not_to include('203.0.113.7')
        expect(log).to include('203.0.113.0') # the masked value is still logged
      end

      it 'never writes the address to the log on the private-exempt path' do
        env = { 'REMOTE_ADDR' => '192.168.1.50' }
        middleware.call(env)

        log = lines.join("\n")
        expect(log).not_to be_empty # guards against a vacuous pass
        expect(log).not_to include('192.168.1.50')
      end

      it 'emits nothing at all under :audit, which keeps the raw IP in env by design' do
        security_config.ip_privacy_config.profile = :audit
        env = { 'REMOTE_ADDR' => '203.0.113.7' }
        middleware.call(env)

        # apply_no_privacy has no logging statements; the raw address stays in
        # env, so there is nothing for a log line to disclose that env does not.
        expect(lines).to be_empty
        expect(env['otto.client_ip']).to eq('203.0.113.7')
      end
    end

    context 'profile configured after the middleware stack is built' do
      it 'honors a profile change made before the first request' do
        # Otto builds its stack at the end of Otto.new, but configuration stays
        # legal until the first request. A privacy flag cached at construction
        # would keep masking here.
        otto = Otto.new
        otto.configure_ip_privacy(profile: :audit)
        env = Rack::MockRequest.env_for('/', 'REMOTE_ADDR' => '203.0.113.7')
        otto.call(env)

        expect(env['otto.client_ip']).to eq('203.0.113.7')
        expect(env['REMOTE_ADDR']).to eq('203.0.113.7')
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
      it 'does not re-resolve or re-mask when a prior pass already set otto.client_ip' do
        env = { 'REMOTE_ADDR' => '203.0.113.7', 'otto.client_ip' => '203.0.113.0' }
        middleware.call(env)

        expect(env['REMOTE_ADDR']).to eq('203.0.113.7')
        expect(env['otto.client_ip']).to eq('203.0.113.0')
      end

      it 'preserves the capability a prior middleware pass installed' do
        allow(Otto.logger).to receive(:warn)
        env = { 'REMOTE_ADDR' => '203.0.113.7' }
        middleware.call(env)
        first = env['otto.ip_match']

        # Second pass through a stacked instance: same closure, still precise.
        middleware.call(env)
        expect(env['otto.ip_match']).to equal(first)
        expect(env['otto.ip_match'].call(['203.0.113.7/32'])).to be true
        # The normal path must never reach the fail-closed repair branch.
        expect(Otto.logger).not_to have_received(:warn)
      end

      it 'installs a fail-closed capability when otto.client_ip was set out-of-contract' do
        # An app or harness set otto.client_ip itself, so the unmasked address
        # is unavailable. Deny rather than match against a possibly-masked
        # value, which would produce false allows on narrow CIDRs.
        allow(Otto.logger).to receive(:warn)
        env = { 'REMOTE_ADDR' => '203.0.113.7', 'otto.client_ip' => '203.0.113.7' }
        middleware.call(env)

        expect(env['otto.ip_match']).to be_a(Proc)
        expect(env['otto.ip_match'].call(['203.0.113.7/32'])).to be false
        expect(env['otto.ip_match'].call(['0.0.0.0/0', '::/0'])).to be false
        expect(Otto.logger).to have_received(:warn).with(/otto.client_ip was set outside/)
      end
    end

    it 'raises for invalid CIDR entries (configuration error surfaces to the caller)' do
      env = { 'REMOTE_ADDR' => '203.0.113.7' }
      middleware.call(env)

      expect { env['otto.ip_match'].call(['bogus']) }.to raise_error(IPAddr::InvalidAddressError)
    end
  end
end
