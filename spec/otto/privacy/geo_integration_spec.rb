# spec/otto/privacy/geo_integration_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Geo-country integration (issue #206)' do
  around(:each) do |example|
    Otto::Privacy::GeoResolver.reset!
    example.run
  ensure
    Otto::Privacy::GeoResolver.reset!
  end

  let(:fixture_db) { 'spec/fixtures/geo/otto-test-country.mmdb' }

  # A reader that records every IP it is asked to look up.
  def spy_reader(record, sink)
    Class.new do
      define_method(:get) do |ip|
        sink << ip
        record
      end
    end.new
  end

  describe 'RedactedFingerprint feeds GeoResolver the masked IP only' do
    it 'looks up the masked /24, never the real address' do
      looked_up = []
      Otto::Privacy::GeoResolver.database_reader =
        spy_reader({ 'country' => { 'iso_code' => 'US' } }, looked_up)

      config = Otto::Privacy::Config.new
      fingerprint = Otto::Privacy::RedactedFingerprint.new({ 'REMOTE_ADDR' => '8.8.8.8' }, config)

      expect(fingerprint.masked_ip).to eq('8.8.8.0')
      expect(fingerprint.country).to eq('US')
      expect(looked_up).to eq(['8.8.8.0'])
      expect(looked_up).not_to include('8.8.8.8')
    end

    it 'looks up the masked /48 for IPv6, never the real address' do
      looked_up = []
      Otto::Privacy::GeoResolver.database_reader =
        spy_reader({ 'country' => { 'iso_code' => 'US' } }, looked_up)

      config = Otto::Privacy::Config.new
      fingerprint = Otto::Privacy::RedactedFingerprint.new({ 'REMOTE_ADDR' => '2001:4860:4860::8888' }, config)

      expect(fingerprint.masked_ip).to eq('2001:4860:4860::')
      expect(fingerprint.country).to eq('US')
      expect(looked_up).to eq(['2001:4860:4860::'])
      expect(looked_up).not_to include('2001:4860:4860::8888')
    end

    it 'does not resolve geo at all when geo is disabled' do
      looked_up = []
      Otto::Privacy::GeoResolver.database_reader =
        spy_reader({ 'country' => { 'iso_code' => 'US' } }, looked_up)

      config = Otto::Privacy::Config.new(geo_enabled: false)
      fingerprint = Otto::Privacy::RedactedFingerprint.new({ 'REMOTE_ADDR' => '8.8.8.8' }, config)

      expect(fingerprint.country).to be_nil
      expect(looked_up).to be_empty
    end
  end

  describe 'Otto#configure_ip_privacy geo options' do
    let(:otto) { Otto.new }

    it 'sets the trusted geo header globally, canonicalized' do
      otto.configure_ip_privacy(geo_header: 'X-Client-Country')
      expect(Otto::Privacy::GeoResolver.geo_header).to eq('HTTP_X_CLIENT_COUNTRY')
    end

    it 'loads the geo database at configuration time' do
      otto.configure_ip_privacy(geo_db_path: fixture_db)
      expect(Otto::Privacy::GeoResolver.database_loaded?).to be true
    end

    it 'fails fast at configuration time for a bad geo_db_path' do
      expect { otto.configure_ip_privacy(geo_db_path: '/no/such/file.mmdb') }
        .to raise_error(Otto::Privacy::GeoResolver::DatabaseError)
    end

    it 'geo: false short-circuits geo and unloads any database (no DB in memory)' do
      otto.configure_ip_privacy(geo_db_path: fixture_db)
      expect(Otto::Privacy::GeoResolver.database_loaded?).to be true

      otto.configure_ip_privacy(geo: false)
      expect(otto.security_config.ip_privacy_config.geo_enabled).to be false
      expect(Otto::Privacy::GeoResolver.database_loaded?).to be false
    end

    it 'geo: false ignores a provided geo_db_path (never opens it)' do
      # A bad path must not raise when geo is disabled — the DB is not loaded.
      expect { otto.configure_ip_privacy(geo: false, geo_db_path: '/no/such/file.mmdb') }
        .not_to raise_error
      expect(Otto::Privacy::GeoResolver.database_loaded?).to be false
    end
  end

  describe 'IPPrivacyMiddleware records the trusted-proxies-configured fact' do
    let(:app) { ->(_env) { [200, {}, ['OK']] } }

    def call_env(security_config, remote_addr: '203.0.113.5', extra: {})
      env = { 'REMOTE_ADDR' => remote_addr }.merge(extra)
      Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config).call(env)
      env
    end

    it 'is false when no trusted proxies are configured' do
      env = call_env(Otto::Security::Config.new)
      expect(env['otto.trusted_proxies_configured']).to be false
    end

    it 'is true when identity-based trusted proxies are configured' do
      config = Otto::Security::Config.new
      config.add_trusted_proxy('203.0.113.0/24')
      env = call_env(config)
      expect(env['otto.trusted_proxies_configured']).to be true
    end

    it 'is false in count-based depth mode (mirrors via_trusted_proxy identity contract)' do
      config = Otto::Security::Config.new
      config.trusted_proxy_depth = 1
      env = call_env(config)
      expect(env['otto.trusted_proxies_configured']).to be false
    end
  end

  describe 'end-to-end geo_country through the middleware' do
    let(:app) { ->(_env) { [200, {}, ['OK']] } }

    def geo_country_for(security_config, env)
      Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config).call(env)
      env['otto.privacy.geo_country']
    end

    it 'honors a CDN header from a trusted proxy' do
      Otto::Privacy::GeoResolver.geo_db_path = fixture_db
      config = Otto::Security::Config.new
      config.add_trusted_proxy('203.0.113.0/24')

      # Peer is the trusted proxy; the forwarded client is a public IP.
      env = {
        'REMOTE_ADDR' => '203.0.113.9',
        'HTTP_X_FORWARDED_FOR' => '81.2.69.42',
        'HTTP_CF_IPCOUNTRY' => 'FR',
      }
      expect(geo_country_for(config, env)).to eq('FR')
    end

    it 'ignores a spoofed CDN header from an untrusted peer and uses the masked-IP DB lookup' do
      Otto::Privacy::GeoResolver.geo_db_path = fixture_db
      config = Otto::Security::Config.new
      config.add_trusted_proxy('10.0.0.0/8') # some proxy, but not this peer

      # Direct (untrusted) connection from a public IP in 8.8.8.0/24 => US,
      # spoofing CF-IPCountry: FR. Header must be ignored; DB must win.
      env = {
        'REMOTE_ADDR' => '8.8.8.8',
        'HTTP_CF_IPCOUNTRY' => 'FR',
      }
      expect(geo_country_for(config, env)).to eq('US')
    end
  end
end
