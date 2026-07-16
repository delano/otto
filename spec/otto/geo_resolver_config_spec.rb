# spec/otto/geo_resolver_config_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Coverage for the configurable geo-header source and the local IP->country
# database fallback added on top of the built-in CDN-header resolution.
RSpec.describe 'Configurable geo resolution' do
  # A minimal MMDB-style reader: any object responding to #get(ip). Records the
  # exact IP it was asked about so we can prove the resolver only ever sees the
  # MASKED address.
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

  describe Otto::Privacy::Config do
    describe '#geo_header=' do
      it 'canonicalizes an HTTP-form header to an env key' do
        config = described_class.new(geo_header: 'X-Client-Country')
        expect(config.geo_header).to eq('HTTP_X_CLIENT_COUNTRY')
      end

      it 'accepts the CGI/env form unchanged' do
        config = described_class.new(geo_header: 'HTTP_X_CLIENT_COUNTRY')
        expect(config.geo_header).to eq('HTTP_X_CLIENT_COUNTRY')
      end

      it 'lower-cases and dash-normalizes input' do
        config = described_class.new(geo_header: 'x-client-country')
        expect(config.geo_header).to eq('HTTP_X_CLIENT_COUNTRY')
      end

      it 'treats nil and blank as no header' do
        expect(described_class.new(geo_header: nil).geo_header).to be_nil
        expect(described_class.new(geo_header: '   ').geo_header).to be_nil
      end
    end

    describe '#geo_db_reader' do
      it 'returns an injected reader' do
        reader = recording_reader({})
        config = described_class.new(geo_db_reader: reader)
        expect(config.geo_db_reader).to equal(reader)
      end

      it 'rejects a reader that does not respond to :get' do
        expect { described_class.new(geo_db_reader: Object.new) }
          .to raise_error(ArgumentError, /must respond to :get/)
      end

      it 'returns nil when geo is disabled (no DB consulted)' do
        reader = recording_reader({})
        config = described_class.new(geo_enabled: false, geo_db_reader: reader)
        expect(config.geo_db_reader).to be_nil
      end

      it 'survives deep_freeze! and stays usable (shallow-frozen reader)' do
        reader = recording_reader('1.2.3.0' => { 'country' => { 'iso_code' => 'US' } })
        config = described_class.new(geo_db_reader: reader)
        config.deep_freeze!

        expect(config).to be_frozen
        expect(config.geo_db_reader).to equal(reader)
      end
    end

    describe '#geo_db_path (boot-time loading)' do
      it 'raises at boot for an unreadable path (not per-request)' do
        expect { described_class.new(geo_db_path: '/no/such/geo.mmdb') }
          .to raise_error(ArgumentError, /not readable/)
      end

      it 'does not load a database when geo is disabled' do
        # geo disabled short-circuits: the (bad) path is never opened, so no
        # boot error and no reader in memory.
        expect { described_class.new(geo_enabled: false, geo_db_path: '/no/such/geo.mmdb') }
          .not_to raise_error
      end
    end

    describe '.canonicalize_geo_header' do
      it 'maps equivalent forms to the same env key' do
        %w[X-Vercel-IP-Country HTTP_X_VERCEL_IP_COUNTRY x-vercel-ip-country].each do |form|
          expect(described_class.canonicalize_geo_header(form)).to eq('HTTP_X_VERCEL_IP_COUNTRY')
        end
      end
    end
  end

  describe Otto::Privacy::GeoResolver do
    describe '.resolve with a configured header' do
      let(:config) { Otto::Privacy::Config.new(geo_header: 'X-Client-Country') }

      it 'prefers the configured header over provider headers' do
        env = { 'HTTP_X_CLIENT_COUNTRY' => 'JP', 'HTTP_CF_IPCOUNTRY' => 'US' }
        expect(described_class.resolve('9.9.9.0', env, config)).to eq('JP')
      end

      it 'ignores an invalid configured code and falls through to providers' do
        env = { 'HTTP_X_CLIENT_COUNTRY' => 'invalid', 'HTTP_CF_IPCOUNTRY' => 'US' }
        expect(described_class.resolve('9.9.9.0', env, config)).to eq('US')
      end

      it 'falls through to range detection when no header matches' do
        expect(described_class.resolve('8.8.8.0', {}, config)).to eq('US')
      end
    end

    describe '.resolve with the Vercel provider header' do
      it 'reads X-Vercel-IP-Country' do
        env = { 'HTTP_X_VERCEL_IP_COUNTRY' => 'DE' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('DE')
      end
    end

    describe '.resolve header trust gate' do
      let(:config) { Otto::Privacy::Config.new(geo_header: 'X-Client-Country') }

      it 'skips both configured and provider headers when headers are untrusted' do
        env = { 'HTTP_X_CLIENT_COUNTRY' => 'JP', 'HTTP_CF_IPCOUNTRY' => 'GB' }
        # 9.9.9.0 (Quad9) resolves to CH by range detection, proving neither
        # spoofable header was consulted.
        expect(described_class.resolve('9.9.9.0', env, config, headers_trusted: false)).to eq('CH')
      end

      it 'still consults the database when headers are untrusted' do
        reader = recording_reader('9.9.9.0' => { 'country' => { 'iso_code' => 'NL' } })
        cfg = Otto::Privacy::Config.new(geo_header: 'X-Client-Country', geo_db_reader: reader)
        env = { 'HTTP_X_CLIENT_COUNTRY' => 'JP' }
        expect(described_class.resolve('9.9.9.0', env, cfg, headers_trusted: false)).to eq('NL')
      end
    end

    describe '.resolve with a database reader' do
      it 'reads GeoLite2-compatible nested results' do
        reader = recording_reader('8.8.8.0' => { 'country' => { 'iso_code' => 'US' } })
        config = Otto::Privacy::Config.new(geo_db_reader: reader)
        expect(described_class.resolve('8.8.8.0', {}, config)).to eq('US')
      end

      it 'reads flat country_code results' do
        reader = recording_reader('5.5.5.0' => { 'country_code' => 'FR' })
        config = Otto::Privacy::Config.new(geo_db_reader: reader)
        expect(described_class.resolve('5.5.5.0', {}, config)).to eq('FR')
      end

      it 'reads a bare country-string result without raising' do
        # A reader returning {'country' => 'US'} must not trip String#dig.
        reader = recording_reader('5.5.5.0' => { 'country' => 'US' })
        config = Otto::Privacy::Config.new(geo_db_reader: reader)
        expect(described_class.resolve('5.5.5.0', {}, config)).to eq('US')
      end

      it 'treats an invalid database code as unknown (authoritative DB)' do
        reader = recording_reader('8.8.8.0' => { 'country' => { 'iso_code' => 'ZZZ' } })
        config = Otto::Privacy::Config.new(geo_db_reader: reader)
        # ZZZ is not a valid 2-letter code. With a database configured, the DB is
        # authoritative: an unusable result is '**', not a range-table guess
        # (8.8.8.0/24 would otherwise be coerced to US).
        expect(described_class.resolve('8.8.8.0', {}, config)).to eq('**')
      end

      it 'returns ** on a database miss for an otherwise unknown IP' do
        reader = recording_reader({}) # every lookup misses
        config = Otto::Privacy::Config.new(geo_db_reader: reader)
        expect(described_class.resolve('203.0.113.0', {}, config)).to eq('**')
      end

      it 'returns ** (not a range guess) when the reader raises' do
        exploding = Class.new do
          def get(_ip)
            raise 'db exploded'
          end
        end.new
        config = Otto::Privacy::Config.new(geo_db_reader: exploding)
        # The lookup error is swallowed (no crash); with an authoritative DB
        # configured, the honest answer is '**' rather than a toy-table guess.
        expect(described_class.resolve('8.8.8.0', {}, config)).to eq('**')
      end
    end

    describe '.resolve IPv6 handling' do
      it 'returns ** for an unknown IPv6 address' do
        expect(described_class.resolve('2001:db8::', {})).to eq('**')
      end

      it 'reads a configured header for an IPv6 request' do
        config = Otto::Privacy::Config.new(geo_header: 'X-Client-Country')
        env = { 'HTTP_X_CLIENT_COUNTRY' => 'SE' }
        expect(described_class.resolve('2001:db8::', env, config)).to eq('SE')
      end

      it 'looks up an IPv6 address in the database' do
        reader = recording_reader('2001:db8::' => { 'country' => { 'iso_code' => 'SE' } })
        config = Otto::Privacy::Config.new(geo_db_reader: reader)
        expect(described_class.resolve('2001:db8::', {}, config)).to eq('SE')
      end
    end

    describe '.resolve backward compatibility' do
      it 'behaves as before when no config is supplied' do
        expect(described_class.resolve('8.8.8.8', { 'HTTP_CF_IPCOUNTRY' => 'GB' })).to eq('GB')
        expect(described_class.resolve('8.8.8.8', {})).to eq('US')
        expect(described_class.resolve('240.0.0.1', {})).to eq('**')
      end
    end
  end

  describe Otto::Security::Config do
    describe '#trusted_proxies_configured?' do
      it 'is false with no matchers configured' do
        expect(described_class.new.trusted_proxies_configured?).to be false
      end

      it 'is true once a trusted proxy is added' do
        config = described_class.new
        config.add_trusted_proxy('10.0.0.1')
        expect(config.trusted_proxies_configured?).to be true
      end

      it 'is false in count-based depth mode (no identity matchers)' do
        config = described_class.new
        config.trusted_proxy_depth = 2
        expect(config.trusted_proxies_configured?).to be false
      end
    end
  end

  describe 'IPPrivacyMiddleware geo integration' do
    let(:app) { ->(_env) { [200, {}, ['OK']] } }

    def run(security_config, env)
      Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config).call(env)
      env
    end

    context 'header trust gate' do
      it 'honors a provider header for a request that arrived via a trusted proxy' do
        sc = Otto::Security::Config.new
        sc.add_trusted_proxy('10.0.0.1')

        env = run(sc, {
                    'REMOTE_ADDR' => '10.0.0.1',
                    'HTTP_X_FORWARDED_FOR' => '8.8.8.8',
                    'HTTP_CF_IPCOUNTRY' => 'GB',
                  })

        expect(env['otto.via_trusted_proxy']).to be true
        expect(env['otto.privacy.geo_country']).to eq('GB')
      end

      it 'ignores a spoofed provider header from a non-trusted-proxy request' do
        sc = Otto::Security::Config.new
        sc.add_trusted_proxy('10.0.0.1')

        # Direct connection from 8.8.8.8 with a forged CF-IPCountry: GB is a lie.
        env = run(sc, { 'REMOTE_ADDR' => '8.8.8.8', 'HTTP_CF_IPCOUNTRY' => 'GB' })

        expect(env['otto.via_trusted_proxy']).to be false
        # Header ignored; masked 8.8.8.0 resolves to US by range detection.
        expect(env['otto.privacy.geo_country']).to eq('US')
      end

      it 'trusts provider headers when no trusted proxies are configured (legacy)' do
        env = run(Otto::Security::Config.new, { 'REMOTE_ADDR' => '8.8.8.8', 'HTTP_CF_IPCOUNTRY' => 'GB' })
        expect(env['otto.privacy.geo_country']).to eq('GB')
      end

      it 'ignores geo headers in count-based depth mode (edge unverifiable)' do
        sc = Otto::Security::Config.new
        sc.trusted_proxy_depth = 1

        # Depth mode can't verify the hop that set CF-IPCountry is a geo-CDN, so
        # the forged GB header is ignored; masked 8.8.8.0 resolves to US.
        env = run(sc, {
                    'REMOTE_ADDR' => '10.0.0.1',
                    'HTTP_X_FORWARDED_FOR' => '8.8.8.8',
                    'HTTP_CF_IPCOUNTRY' => 'GB',
                  })

        expect(env['otto.privacy.geo_country']).to eq('US')
      end
    end

    context 'database fallback' do
      it 'looks up the MASKED IP only, never the real address' do
        reader = recording_reader('8.8.8.0' => { 'country' => { 'iso_code' => 'NL' } })
        sc = Otto::Security::Config.new
        sc.ip_privacy_config.geo_db_reader = reader
        sc.ip_privacy_config.load_geo_database!

        env = run(sc, { 'REMOTE_ADDR' => '8.8.8.8' })

        expect(env['otto.privacy.geo_country']).to eq('NL')
        expect(reader.seen).to eq(['8.8.8.0'])
        expect(reader.seen).not_to include('8.8.8.8')
      end

      it 'does not consult the database when geo is disabled' do
        reader = recording_reader('8.8.8.0' => { 'country' => { 'iso_code' => 'NL' } })
        sc = Otto::Security::Config.new
        sc.ip_privacy_config.geo_db_reader = reader
        sc.ip_privacy_config.geo_enabled = false
        sc.ip_privacy_config.load_geo_database!

        env = run(sc, { 'REMOTE_ADDR' => '8.8.8.8' })

        expect(env['otto.privacy.geo_country']).to be_nil
        expect(reader.seen).to be_empty
      end
    end

    context 'custom resolver sealing' do
      after { Otto::Privacy::GeoResolver.custom_resolver = nil }

      it 'hands the custom resolver the masked IP in both the argument and env' do
        seen = {}
        Otto::Privacy::GeoResolver.custom_resolver = lambda do |ip, resolver_env|
          seen[:ip] = ip
          seen[:remote_addr] = resolver_env['REMOTE_ADDR']
          seen[:xff] = resolver_env['HTTP_X_FORWARDED_FOR']
          'PT'
        end

        env = run(Otto::Security::Config.new,
                  { 'REMOTE_ADDR' => '8.8.8.8', 'HTTP_X_FORWARDED_FOR' => '8.8.8.8' })

        expect(env['otto.privacy.geo_country']).to eq('PT')
        # The precise host is never exposed to the resolver, by argument or env.
        expect(seen[:ip]).to eq('8.8.8.0')
        expect(seen[:remote_addr]).to eq('8.8.8.0')
        expect(seen[:xff]).to eq('8.8.8.0')
        expect(seen.values).not_to include('8.8.8.8')
      end

      it 'does not leak resolver env mutations back into the request env' do
        Otto::Privacy::GeoResolver.custom_resolver = lambda do |_ip, resolver_env|
          resolver_env['REMOTE_ADDR'] = 'tampered' # mutate the masked COPY
          'PT'
        end

        env = { 'REMOTE_ADDR' => '8.8.8.8' }
        Otto::Privacy::RedactedFingerprint.new(env, Otto::Privacy::Config.new)

        # geo_env hands the resolver a dup, so the request env is untouched.
        expect(env['REMOTE_ADDR']).to eq('8.8.8.8')
      end

      it 'strips the RFC 7239 Forwarded header from the resolver env view' do
        captured = {}
        Otto::Privacy::GeoResolver.custom_resolver = lambda do |ip, resolver_env|
          captured[:ip] = ip
          captured[:has_forwarded] = resolver_env.key?('HTTP_FORWARDED')
          captured[:values] = resolver_env.values
          'PT'
        end

        # HTTP_FORWARDED carries the real client IP in its `for=` token; Otto
        # reads it as authoritative in depth mode. It must not reach the resolver.
        env = { 'REMOTE_ADDR' => '203.0.113.77', 'HTTP_FORWARDED' => 'for=203.0.113.77;proto=https' }
        Otto::Privacy::RedactedFingerprint.new(env, Otto::Privacy::Config.new)

        expect(captured[:ip]).to eq('203.0.113.0')
        expect(captured[:has_forwarded]).to be false
        leaked = captured[:values].any? { |v| v.is_a?(String) && v.include?('203.0.113.77') }
        expect(leaked).to be false
        # The real request env is untouched (the resolver saw a masked dup).
        expect(env['HTTP_FORWARDED']).to eq('for=203.0.113.77;proto=https')
      end
    end
  end

  describe 'Otto#configure_ip_privacy geo options' do
    it 'canonicalizes and stores a configured header' do
      otto = create_minimal_otto(['GET / TestApp.index'])
      otto.configure_ip_privacy(geo_header: 'X-Client-Country')

      expect(otto.security_config.ip_privacy_config.geo_header).to eq('HTTP_X_CLIENT_COUNTRY')
    end

    it 'attaches an injected reader' do
      reader = recording_reader({})
      otto = create_minimal_otto(['GET / TestApp.index'])
      otto.configure_ip_privacy(geo_db_reader: reader)

      expect(otto.security_config.ip_privacy_config.geo_db_reader).to equal(reader)
    end

    it 'raises at configuration time for a bad database path' do
      otto = create_minimal_otto(['GET / TestApp.index'])
      expect { otto.configure_ip_privacy(geo_db_path: '/no/such/geo.mmdb') }
        .to raise_error(ArgumentError, /not readable/)
    end

    it 'stops consulting the database once geo is disabled' do
      reader = recording_reader({})
      otto = create_minimal_otto(['GET / TestApp.index'])
      otto.configure_ip_privacy(geo_db_reader: reader)
      expect(otto.security_config.ip_privacy_config.geo_db_reader).to equal(reader)

      otto.configure_ip_privacy(geo: false)
      expect(otto.security_config.ip_privacy_config.geo_db_reader).to be_nil
    end
  end

  # Exercises the real MaxMind::DB reader against a generated fixture (see
  # spec/support/mmdb_fixture.rb), so the geo_db_path -> reader -> get path is
  # verified against the genuine library, not only a duck-typed fake. Skipped
  # when the optional maxmind-db gem is unavailable.
  describe 'real maxmind-db reader integration', :maxmind do
    before(:all) do
      require 'maxmind/db'
    rescue LoadError
      skip 'maxmind-db gem not installed'
    end

    let(:db_path) do
      MmdbFixture.country_db_file([
                                    ['1.2.3.0', 24, 'US'],
                                    ['5.5.5.0', 24, 'FR'],
                                    ['2.0.0.0', 8, 'GB'],
                                  ])
    end

    it 'opens a database by path and resolves via the real reader' do
      config = Otto::Privacy::Config.new(geo_db_path: db_path)

      expect(config.geo_db_reader).to be_a(MaxMind::DB)
      expect(Otto::Privacy::GeoResolver.resolve('1.2.3.4', {}, config)).to eq('US')
      expect(Otto::Privacy::GeoResolver.resolve('5.5.5.9', {}, config)).to eq('FR')
      expect(Otto::Privacy::GeoResolver.resolve('2.9.9.9', {}, config)).to eq('GB')
    end

    it 'returns ** for an address absent from the real database (authoritative)' do
      config = Otto::Privacy::Config.new(geo_db_path: db_path)
      expect(Otto::Privacy::GeoResolver.resolve('9.9.9.9', {}, config)).to eq('**')
    end

    it 'keeps the real reader usable after the config is deep-frozen' do
      config = Otto::Privacy::Config.new(geo_db_path: db_path)
      config.deep_freeze!

      expect(config).to be_frozen
      expect(config.geo_db_reader).to be_frozen
      expect(Otto::Privacy::GeoResolver.resolve('1.2.3.4', {}, config)).to eq('US')
    end

    it 'resolves the masked /24 identically to the real host address' do
      config = Otto::Privacy::Config.new(geo_db_path: db_path)
      # The middleware would pass 1.2.3.0; a direct real IP masks to the same.
      expect(Otto::Privacy::GeoResolver.resolve('1.2.3.255', {}, config)).to eq('US')
      expect(Otto::Privacy::GeoResolver.resolve('1.2.3.0', {}, config)).to eq('US')
    end

    it 'raises a clear error at boot for a non-mmdb file' do
      not_mmdb = MmdbFixture.country_db_file([]) # will be truncated below
      File.write(not_mmdb, 'this is not an mmdb')
      expect { Otto::Privacy::Config.new(geo_db_path: not_mmdb) }
        .to raise_error(ArgumentError, /Failed to open geo_db_path/)
    end
  end
end
