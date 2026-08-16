# spec/otto/privacy_enrichment_resolvers_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'otto/env_keys' # opt-in constants module, not loaded by `require 'otto'`

# Coverage for the opt-in enrichment signals layered on top of geo: ASN
# resolution (masked-IP database lookup) and anonymizer classification (the
# one deliberate unmasked-IP lookup). The load-bearing assertions are the
# privacy boundaries: WHICH address each resolver is handed, and that a
# disabled signal yields nil everywhere rather than '**'.
RSpec.describe Otto::Privacy, :aggregate_failures do
  # Same shape as the geo specs' recording reader: proves exactly which IP a
  # resolver was asked about, not just what it answered.
  def asn_record(number)
    { 'autonomous_system_number' => number }
  end

  def recording_reader(mapping)
    Class.new do
      attr_reader :seen

      def initialize(mapping)
        @mapping = mapping
        @seen = []
      end

      def get(ip)
        @seen << ip
        @mapping[ip]
      end
    end.new(mapping)
  end

  describe Otto::Privacy::AsnResolver do
    it 'formats a resolved ASN as AS<number>' do
      reader = recording_reader('203.0.113.0' => { 'autonomous_system_number' => 15_169 })
      config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: reader)
      expect(described_class.resolve('203.0.113.0', config)).to eq('AS15169')
    end

    it 'accepts the nested asn-map layout some combined builds use' do
      reader = recording_reader('203.0.113.0' => { 'asn' => { 'autonomous_system_number' => 13_335 } })
      config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: reader)
      expect(described_class.resolve('203.0.113.0', config)).to eq('AS13335')
    end

    it 'returns ** when the database has no record' do
      config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: recording_reader({}))
      expect(described_class.resolve('203.0.113.0', config)).to eq('**')
    end

    it 'returns ** with no configured database' do
      config = Otto::Privacy::Config.new(asn_enabled: true)
      expect(described_class.resolve('203.0.113.0', config)).to eq('**')
    end

    it 'treats reserved ASNs (0, AS_TRANS) as no answer' do
      [0, 23_456].each do |reserved|
        reader = recording_reader('203.0.113.0' => { 'autonomous_system_number' => reserved })
        config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: reader)
        expect(described_class.resolve('203.0.113.0', config)).to eq('**')
      end
    end

    it 'accepts the highest assignable ASN and rejects the reserved successor' do
      max_reader = recording_reader('203.0.113.0' => { 'autonomous_system_number' => 4_294_967_294 })
      reserved_reader = recording_reader('203.0.113.0' => { 'autonomous_system_number' => 4_294_967_295 })

      max_config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: max_reader)
      reserved_config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: reserved_reader)

      expect(described_class.resolve('203.0.113.0', max_config)).to eq('AS4294967294')
      expect(described_class.resolve('203.0.113.0', reserved_config)).to eq('**')
    end

    it 'rejects a non-Integer ASN value rather than formatting garbage' do
      reader = recording_reader('203.0.113.0' => { 'autonomous_system_number' => '15169' })
      config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: reader)
      expect(described_class.resolve('203.0.113.0', config)).to eq('**')
    end

    it 'survives a raising reader (a database read must never crash a request)' do
      raising = Class.new { def get(_ip) = raise(IOError, 'corrupt mmdb') }.new
      config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: raising)
      expect(described_class.resolve('203.0.113.0', config)).to eq('**')
    end

    it 'treats a config without an ASN reader accessor as unknown rather than raising' do
      expect(described_class.resolve('203.0.113.0', Object.new)).to eq('**')
    end

    it 're-masks its input, so even a raw address is looked up masked' do
      reader = recording_reader({})
      config = Otto::Privacy::Config.new(asn_enabled: true, asn_db_reader: reader)
      described_class.resolve('203.0.113.42', config)
      expect(reader.seen).to eq(['203.0.113.0'])
    end
  end

  describe Otto::Privacy::AnonymizerResolver do
    def config_with(mapping)
      Otto::Privacy::Config.new(anonymizer_enabled: true,
                                anonymizer_db_reader: recording_reader(mapping))
    end

    it 'classifies a Tor exit node' do
      config = config_with('203.0.113.42' => { 'is_tor_exit_node' => true })
      expect(described_class.resolve('203.0.113.42', config)).to eq('tor')
    end

    it 'prefers the most specific flag when several are set' do
      config = config_with('203.0.113.42' => { 'is_hosting_provider' => true, 'is_tor_exit_node' => true })
      expect(described_class.resolve('203.0.113.42', config)).to eq('tor')
    end

    it "returns 'none' for an address the database does not list" do
      config = config_with({})
      expect(described_class.resolve('203.0.113.42', config)).to eq('none')
    end

    it "returns 'none' for a record with every flag absent" do
      config = config_with('203.0.113.42' => {})
      expect(described_class.resolve('203.0.113.42', config)).to eq('none')
    end

    it 'accepts string-backed truthy vendor flags' do
      %w[true 1].each do |value|
        config = config_with('203.0.113.42' => { 'is_anonymous_vpn' => value })
        expect(described_class.resolve('203.0.113.42', config)).to eq('vpn')
      end
    end

    it 'returns ** for a malformed database record' do
      config = config_with('203.0.113.42' => 42)
      expect(described_class.resolve('203.0.113.42', config)).to eq('**')
    end

    it 'returns ** with no configured database (no answer is not evidence)' do
      config = Otto::Privacy::Config.new(anonymizer_enabled: true)
      expect(described_class.resolve('203.0.113.42', config)).to eq('**')
    end

    it 'survives a raising reader' do
      raising = Class.new { def get(_ip) = raise(IOError, 'corrupt mmdb') }.new
      config = Otto::Privacy::Config.new(anonymizer_enabled: true, anonymizer_db_reader: raising)
      expect(described_class.resolve('203.0.113.42', config)).to eq('**')
    end

    it 'treats a config without an anonymizer reader accessor as unknown rather than raising' do
      expect(described_class.resolve('203.0.113.42', Object.new)).to eq('**')
    end

    it 'is handed the UNMASKED address (per-node data breaks the /24 equivalence)' do
      reader = recording_reader({})
      config = Otto::Privacy::Config.new(anonymizer_enabled: true, anonymizer_db_reader: reader)
      described_class.resolve('203.0.113.42', config)
      expect(reader.seen).to eq(['203.0.113.42'])
    end
  end

  describe Otto::Privacy::Config do
    it 'defaults both signals off, unlike geo' do
      config = described_class.new
      expect(config.asn_enabled).to be(false)
      expect(config.anonymizer_enabled).to be(false)
      expect(config.geo_enabled).to be(true)
    end

    it 'gates the readers on the enabled flags' do
      reader = recording_reader({})
      config = described_class.new(asn_db_reader: reader, anonymizer_db_reader: reader)
      expect(config.asn_db_reader).to be_nil
      expect(config.anonymizer_db_reader).to be_nil
    end

    it 'rejects readers that do not respond to :get, naming the right option' do
      expect { described_class.new(asn_db_reader: Object.new) }
        .to raise_error(ArgumentError, /asn_db_reader must respond to :get/)
      expect { described_class.new(anonymizer_db_reader: Object.new) }
        .to raise_error(ArgumentError, /anonymizer_db_reader must respond to :get/)
    end

    it 'fails at boot on an unreadable path, naming the right option' do
      expect { described_class.new(asn_enabled: true, asn_db_path: '/nonexistent.mmdb') }
        .to raise_error(ArgumentError, /asn_db_path is not readable/)
      expect { described_class.new(anonymizer_enabled: true, anonymizer_db_path: '/nonexistent.mmdb') }
        .to raise_error(ArgumentError, /anonymizer_db_path is not readable/)
    end

    it 'does not open a database for a disabled signal (no boot cost unasked)' do
      config = described_class.new(asn_db_path: '/nonexistent.mmdb')
      expect(config.asn_db_path).to eq('/nonexistent.mmdb')
      expect(config.asn_db_reader).to be_nil
    end
  end

  describe 'configure_ip_privacy wiring' do
    it 'enables and threads readers through in one call' do
      reader = recording_reader('203.0.113.0' => { 'autonomous_system_number' => 64_496 })
      otto = Otto.new
      otto.configure_ip_privacy(asn: true, asn_db_reader: reader)
      config = otto.security_config.ip_privacy_config
      expect([config.asn_enabled, config.asn_db_reader]).to eq([true, reader])
    end

    it 'leaves both signals untouched when their kwargs are omitted' do
      otto = Otto.new
      otto.configure_ip_privacy(asn: true, asn_db_reader: recording_reader({}))
      otto.configure_ip_privacy(octet_precision: 2)
      expect(otto.security_config.ip_privacy_config.asn_enabled).to be(true)
    end

    it 'preserves a working ASN reader when a replacement path cannot be opened' do
      reader = recording_reader('203.0.113.0' => asn_record(15_169))
      otto = Otto.new
      otto.configure_ip_privacy(asn: true, asn_db_reader: reader)

      expect do
        otto.configure_ip_privacy(asn_db_path: '/nonexistent.mmdb')
      end.to raise_error(ArgumentError, /asn_db_path is not readable/)

      config = otto.security_config.ip_privacy_config
      expect(Otto::Privacy::AsnResolver.resolve('203.0.113.42', config)).to eq('AS15169')
    end

    it 'preserves a working anonymizer reader when a replacement path cannot be opened' do
      reader = recording_reader('203.0.113.42' => { 'is_tor_exit_node' => true })
      otto = Otto.new
      otto.configure_ip_privacy(anonymizer: true, anonymizer_db_reader: reader)

      expect do
        otto.configure_ip_privacy(anonymizer_db_path: '/nonexistent.mmdb')
      end.to raise_error(ArgumentError, /anonymizer_db_path is not readable/)

      config = otto.security_config.ip_privacy_config
      expect(Otto::Privacy::AnonymizerResolver.resolve('203.0.113.42', config)).to eq('tor')
    end
  end

  describe 'middleware env and Request accessors' do
    let(:inner_app) { ->(env) { [200, { 'content-type' => 'text/plain' }, [env.inspect]] } }

    def build_otto(**privacy_opts)
      otto = Otto.new
      otto.configure_ip_privacy(**privacy_opts) unless privacy_opts.empty?
      otto
    end

    def run_middleware(otto, ip = '203.0.113.42')
      env = { 'REMOTE_ADDR' => ip, 'rack.input' => StringIO.new }
      Otto::Security::Middleware::IPPrivacyMiddleware.new(inner_app, otto.security_config).call(env)
      env
    end

    def enrichment_otto(asn_reader, anonymizer_reader)
      build_otto(asn: true, asn_db_reader: asn_reader,
                 anonymizer: true, anonymizer_db_reader: anonymizer_reader)
    end

    def enrichment_labels(env)
      [env[Otto::EnvKeys::Privacy::ASN], env[Otto::EnvKeys::Privacy::ANONYMIZER],
       Otto::Request.new(env).asn, Otto::Request.new(env).anonymizer]
    end

    it 'is nil in env and on Request when not opted in (off, not unknown)' do
      env = run_middleware(build_otto)
      request = Otto::Request.new(env)
      expect([env['otto.privacy.asn'], env['otto.privacy.anonymizer'], request.asn, request.anonymizer]).to all(be_nil)
    end

    it 'exposes both labels via env keys and Request accessors when enabled' do
      otto = enrichment_otto(recording_reader('203.0.113.0' => asn_record(15_169)),
                             recording_reader('203.0.113.42' => { 'is_anonymous_vpn' => true }))
      expect(enrichment_labels(run_middleware(otto))).to eq(%w[AS15169 vpn AS15169 vpn])
    end

    it 'hands the ASN reader the masked IP and the anonymizer reader the real one' do
      asn_reader = recording_reader({})
      anonymizer_reader = recording_reader({})
      run_middleware(enrichment_otto(asn_reader, anonymizer_reader))
      expect([asn_reader.seen, anonymizer_reader.seen]).to eq([['203.0.113.0'], ['203.0.113.42']])
    end

    it 'produces neither signal for privacy-exempt private IPs' do
      env = run_middleware(enrichment_otto(recording_reader({}), recording_reader({})), '127.0.0.1')
      expect(env).not_to have_key('otto.privacy.asn')
      expect(env).not_to have_key('otto.privacy.anonymizer')
    end

    it 'includes both fields in the fingerprint hash' do
      config = Otto::Privacy::Config.new(asn_enabled: true,
                                          asn_db_reader: recording_reader('203.0.113.0' => asn_record(64_496)),
                                          anonymizer_enabled: true, anonymizer_db_reader: recording_reader({}))
      fingerprint = Otto::Privacy::RedactedFingerprint.new({ 'REMOTE_ADDR' => '203.0.113.42' }, config)
      expect(fingerprint.to_h).to include(asn: 'AS64496', anonymizer: 'none')
    end
  end
end
