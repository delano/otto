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

      it 'survives deep_freeze! and stays usable (reader held at class level)' do
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

      it 'ignores an invalid database code and falls through to range detection' do
        reader = recording_reader('8.8.8.0' => { 'country' => { 'iso_code' => 'ZZZ' } })
        config = Otto::Privacy::Config.new(geo_db_reader: reader)
        # ZZZ is not a valid 2-letter code -> range detection (8.8.8.0/24 -> US)
        expect(described_class.resolve('8.8.8.0', {}, config)).to eq('US')
      end

      it 'returns ** on a database miss for an otherwise unknown IP' do
        reader = recording_reader({}) # every lookup misses
        config = Otto::Privacy::Config.new(geo_db_reader: reader)
        expect(described_class.resolve('203.0.113.0', {}, config)).to eq('**')
      end

      it 'never crashes a request when the reader raises' do
        exploding = Class.new do
          def get(_ip)
            raise 'db exploded'
          end
        end.new
        config = Otto::Privacy::Config.new(geo_db_reader: exploding)
        # Falls through to range detection (8.8.8.0/24 -> US)
        expect(described_class.resolve('8.8.8.0', {}, config)).to eq('US')
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
end
