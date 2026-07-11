# spec/otto/privacy/geo_resolver_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Privacy::GeoResolver do
  # GeoResolver configuration is process-global (boot-time contract), so reset
  # it around every example — specs run in random order.
  around(:each) do |example|
    described_class.reset!
    example.run
  ensure
    described_class.reset!
  end

  # Tiny, synthetic, license-clean country database (see
  # spec/fixtures/geo/generate_fixture.py). Networks: 81.2.69.0/24 => GB,
  # 8.8.8.0/24 => US, 1.1.1.0/24 => AU, 89.160.20.0/24 => SE,
  # 203.0.113.0/24 => JP, 2001:4860:4860::/48 => US, 2a02:6b8::/32 => RU.
  let(:fixture_db) { 'spec/fixtures/geo/otto-test-country.mmdb' }

  # Build a fake MMDB reader returning +record+ for any lookup.
  def reader_returning(record)
    Class.new do
      define_method(:get) { |_ip| record }
    end.new
  end

  describe '.resolve' do
    context 'unresolvable input' do
      it 'returns UNKNOWN for nil IP' do
        expect(described_class.resolve(nil, {})).to eq('**')
      end

      it 'returns UNKNOWN for empty IP' do
        expect(described_class.resolve('', {})).to eq('**')
      end

      it 'returns UNKNOWN when there are no sources at all' do
        expect(described_class.resolve('203.0.113.7', {})).to eq('**')
      end
    end

    context 'application-configured geo header' do
      it 'uses the configured header and canonicalizes an HTTP header name' do
        described_class.geo_header = 'X-Client-Country'
        expect(described_class.geo_header).to eq('HTTP_X_CLIENT_COUNTRY')

        env = { 'HTTP_X_CLIENT_COUNTRY' => 'FR' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('FR')
      end

      it 'accepts an already-CGI env key form' do
        described_class.geo_header = 'HTTP_X_CLIENT_COUNTRY'
        expect(described_class.geo_header).to eq('HTTP_X_CLIENT_COUNTRY')
      end

      it 'accepts a lowercase header name' do
        described_class.geo_header = 'x-client-country'
        expect(described_class.geo_header).to eq('HTTP_X_CLIENT_COUNTRY')
      end

      it 'clears the configured header on nil/blank' do
        described_class.geo_header = 'X-Client-Country'
        described_class.geo_header = ''
        expect(described_class.geo_header).to be_nil
        described_class.geo_header = '  '
        expect(described_class.geo_header).to be_nil
      end

      it 'wins over built-in provider headers' do
        described_class.geo_header = 'X-Client-Country'
        env = { 'HTTP_X_CLIENT_COUNTRY' => 'FR', 'HTTP_CF_IPCOUNTRY' => 'US' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('FR')
      end

      it 'falls through to provider headers when the configured header is invalid' do
        described_class.geo_header = 'X-Client-Country'
        env = { 'HTTP_X_CLIENT_COUNTRY' => 'invalid', 'HTTP_CF_IPCOUNTRY' => 'US' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('US')
      end

      it 'falls through when the configured header is absent' do
        described_class.geo_header = 'X-Client-Country'
        env = { 'HTTP_CF_IPCOUNTRY' => 'US' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('US')
      end
    end

    context 'CDN/infrastructure provider headers' do
      {
        'HTTP_CF_IPCOUNTRY' => 'US',
        'HTTP_CLOUDFRONT_VIEWER_COUNTRY' => 'GB',
        'HTTP_FASTLY_CLIENT_IP_COUNTRY' => 'DE',
        'HTTP_X_AZURE_CLIENTIP_COUNTRY' => 'CA',
        'HTTP_X_VERCEL_IP_COUNTRY' => 'NL',
        'HTTP_X_GEO_COUNTRY' => 'JP',
        'HTTP_X_COUNTRY_CODE' => 'AU',
        'HTTP_COUNTRY_CODE' => 'BR',
      }.each do |header, code|
        it "uses #{header}" do
          expect(described_class.resolve('1.2.3.4', { header => code })).to eq(code)
        end
      end

      it 'parses the Akamai Edgescape header' do
        env = { 'HTTP_X_AKAMAI_EDGESCAPE' => 'country_code=FR,region_code=IDF,city=PARIS' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('FR')
      end

      it 'adds Vercel among the recognized providers (issue #206)' do
        expect(described_class.resolve('1.2.3.4', { 'HTTP_X_VERCEL_IP_COUNTRY' => 'DE' })).to eq('DE')
      end
    end

    context 'provider header priority' do
      it 'prefers Cloudflare over CloudFront' do
        env = { 'HTTP_CF_IPCOUNTRY' => 'US', 'HTTP_CLOUDFRONT_VIEWER_COUNTRY' => 'GB' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('US')
      end

      it 'prefers CloudFront over Fastly' do
        env = { 'HTTP_CLOUDFRONT_VIEWER_COUNTRY' => 'GB', 'HTTP_FASTLY_CLIENT_IP_COUNTRY' => 'DE' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('GB')
      end

      it 'prefers a named provider (Vercel) over semi-standard headers' do
        env = { 'HTTP_X_VERCEL_IP_COUNTRY' => 'NL', 'HTTP_X_GEO_COUNTRY' => 'JP' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('NL')
      end
    end

    context 'Akamai Edgescape parsing' do
      it 'extracts from a full header' do
        env = { 'HTTP_X_AKAMAI_EDGESCAPE' => 'country_code=US,region_code=CA,city=LA' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('US')
      end

      it 'extracts from the middle of the parameter list' do
        env = { 'HTTP_X_AKAMAI_EDGESCAPE' => 'foo=bar,country_code=DE,baz=qux' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('DE')
      end

      it 'ignores a malformed header' do
        env = { 'HTTP_X_AKAMAI_EDGESCAPE' => 'invalid_format' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('**')
      end

      it 'ignores an invalid embedded country code' do
        env = { 'HTTP_X_AKAMAI_EDGESCAPE' => 'country_code=INVALID' }
        expect(described_class.resolve('1.2.3.4', env)).to eq('**')
      end
    end

    context 'country-code validation' do
      it 'ignores lowercase codes' do
        expect(described_class.resolve('1.2.3.4', { 'HTTP_CF_IPCOUNTRY' => 'us' })).to eq('**')
      end

      it 'ignores 3-letter codes' do
        expect(described_class.resolve('1.2.3.4', { 'HTTP_CF_IPCOUNTRY' => 'USA' })).to eq('**')
      end

      it 'ignores single-letter codes' do
        expect(described_class.resolve('1.2.3.4', { 'HTTP_CF_IPCOUNTRY' => 'U' })).to eq('**')
      end

      it 'ignores non-string values' do
        expect(described_class.resolve('1.2.3.4', { 'HTTP_CF_IPCOUNTRY' => 123 })).to eq('**')
      end

      it 'ignores empty values' do
        expect(described_class.resolve('1.2.3.4', { 'HTTP_CF_IPCOUNTRY' => '' })).to eq('**')
      end
    end

    context 'custom resolver' do
      it 'is used when configured' do
        described_class.custom_resolver = ->(ip, _env) { ip == '1.2.3.4' ? 'XX' : nil }
        expect(described_class.resolve('1.2.3.4', {})).to eq('XX')
      end

      it 'accepts a callable object' do
        klass = Class.new { def call(_ip, _env) = 'JP' }
        described_class.custom_resolver = klass.new
        expect(described_class.resolve('1.2.3.4', {})).to eq('JP')
      end

      it 'validates the returned country code and falls through when invalid' do
        described_class.custom_resolver = ->(_ip, _env) { 'INVALID' }
        expect(described_class.resolve('1.2.3.4', {})).to eq('**')
      end

      it 'falls through when it returns nil' do
        described_class.custom_resolver = ->(_ip, _env) { nil }
        expect(described_class.resolve('1.2.3.4', {})).to eq('**')
      end

      it 'never crashes the request when it raises' do
        described_class.custom_resolver = ->(_ip, _env) { raise 'boom' }
        expect(described_class.resolve('1.2.3.4', {})).to eq('**')
      end

      it 'raises ArgumentError for a non-callable resolver' do
        expect { described_class.custom_resolver = 'nope' }
          .to raise_error(ArgumentError, /must respond to :call/)
      end

      it 'is outranked by trusted headers' do
        described_class.custom_resolver = ->(_ip, _env) { 'XX' }
        expect(described_class.resolve('1.2.3.4', { 'HTTP_CF_IPCOUNTRY' => 'US' })).to eq('US')
      end
    end

    context 'local MMDB database (fixture-backed)' do
      before { described_class.geo_db_path = fixture_db }

      it 'reports the database as loaded' do
        expect(described_class.database_loaded?).to be true
        expect(described_class.geo_db_path).to eq(fixture_db)
      end

      it 'resolves an IPv4 country from the database' do
        expect(described_class.resolve('81.2.69.10', {})).to eq('GB')
      end

      it 'resolves a masked /24 IP to the same country as the real IP' do
        # 8.8.8.8 masks to 8.8.8.0; both live in 8.8.8.0/24 => US.
        expect(described_class.resolve('8.8.8.0', {})).to eq('US')
        expect(described_class.resolve('8.8.8.8', {})).to eq('US')
      end

      it 'resolves an IPv6 country from the database' do
        expect(described_class.resolve('2001:4860:4860::8888', {})).to eq('US')
        expect(described_class.resolve('2a02:6b8::1', {})).to eq('RU')
      end

      it 'returns UNKNOWN for an address not in the database' do
        expect(described_class.resolve('240.0.0.1', {})).to eq('**')
      end

      it 'never looks up private/localhost addresses' do
        expect(described_class.resolve('192.168.1.1', {})).to eq('**')
        expect(described_class.resolve('127.0.0.1', {})).to eq('**')
      end

      it 'is outranked by a trusted provider header' do
        expect(described_class.resolve('81.2.69.10', { 'HTTP_CF_IPCOUNTRY' => 'US' })).to eq('US')
      end

      it 'is outranked by the custom resolver' do
        described_class.custom_resolver = ->(_ip, _env) { 'ZZ' }
        expect(described_class.resolve('81.2.69.10', {})).to eq('ZZ')
      end
    end

    context 'MMDB record schema variants (injected reader)' do
      it 'reads GeoLite2-style country.iso_code' do
        described_class.database_reader = reader_returning({ 'country' => { 'iso_code' => 'US' } })
        expect(described_class.resolve('9.9.9.9', {})).to eq('US')
      end

      it 'falls back to registered_country.iso_code' do
        described_class.database_reader = reader_returning({ 'registered_country' => { 'iso_code' => 'CA' } })
        expect(described_class.resolve('9.9.9.9', {})).to eq('CA')
      end

      it 'reads a flat country_code schema' do
        described_class.database_reader = reader_returning({ 'country_code' => 'GB' })
        expect(described_class.resolve('9.9.9.9', {})).to eq('GB')
      end

      it 'reads a bare string country' do
        described_class.database_reader = reader_returning({ 'country' => 'JP' })
        expect(described_class.resolve('9.9.9.9', {})).to eq('JP')
      end

      it 'ignores an invalid code in the record' do
        described_class.database_reader = reader_returning({ 'country' => { 'iso_code' => 'usa' } })
        expect(described_class.resolve('9.9.9.9', {})).to eq('**')
      end

      it 'ignores a nil record' do
        described_class.database_reader = reader_returning(nil)
        expect(described_class.resolve('9.9.9.9', {})).to eq('**')
      end

      it 'degrades to UNKNOWN when the reader raises' do
        reader = Class.new { def get(_ip) = raise('reader exploded') }.new
        described_class.database_reader = reader
        expect(described_class.resolve('9.9.9.9', {})).to eq('**')
      end
    end

    context 'header trust gating (spoofing defense)' do
      let(:spoofed) { { 'HTTP_CF_IPCOUNTRY' => 'FR' } }

      it 'trusts headers with no middleware decision present (standalone/legacy)' do
        expect(described_class.resolve('8.8.8.0', spoofed)).to eq('FR')
      end

      it 'trusts headers when the request arrived via a trusted proxy' do
        env = spoofed.merge('otto.via_trusted_proxy' => true, 'otto.trusted_proxies_configured' => true)
        expect(described_class.resolve('8.8.8.0', env)).to eq('FR')
      end

      it 'trusts headers when no trusted proxies are configured' do
        env = spoofed.merge('otto.via_trusted_proxy' => false, 'otto.trusted_proxies_configured' => false)
        expect(described_class.resolve('8.8.8.0', env)).to eq('FR')
      end

      it 'skips spoofable headers when proxies are configured but the request did not arrive via one' do
        described_class.geo_db_path = fixture_db
        env = spoofed.merge('otto.via_trusted_proxy' => false, 'otto.trusted_proxies_configured' => true)
        # Header ignored; falls through to the DB lookup on 8.8.8.0 => US.
        expect(described_class.resolve('8.8.8.0', env)).to eq('US')
      end

      it 'also gates the application-configured header' do
        described_class.geo_header = 'X-Client-Country'
        env = {
          'HTTP_X_CLIENT_COUNTRY' => 'FR',
          'otto.via_trusted_proxy' => false,
          'otto.trusted_proxies_configured' => true,
        }
        expect(described_class.resolve('203.0.113.9', env)).to eq('**')
      end
    end
  end

  describe '.geo_db_path=' do
    it 'raises a DatabaseError at boot for a missing file' do
      expect { described_class.geo_db_path = '/no/such/file.mmdb' }
        .to raise_error(Otto::Privacy::GeoResolver::DatabaseError, /not found/)
    end

    it 'raises a DatabaseError at boot for a non-MMDB file' do
      require 'tempfile'
      Tempfile.create(['not-a-db', '.mmdb']) do |f|
        f.write('definitely not an mmdb')
        f.flush
        expect { described_class.geo_db_path = f.path }
          .to raise_error(Otto::Privacy::GeoResolver::DatabaseError, /not a valid MMDB/)
      end
    end

    it 'surfaces a helpful DatabaseError when the maxmind-db gem is unavailable' do
      allow(described_class).to receive(:require).with('maxmind/db').and_raise(LoadError.new('cannot load such file -- maxmind/db'))
      expect { described_class.geo_db_path = fixture_db }
        .to raise_error(Otto::Privacy::GeoResolver::DatabaseError, /maxmind-db/)
    end

    it 'unloads the database when set to an empty string' do
      described_class.geo_db_path = fixture_db
      expect(described_class.database_loaded?).to be true
      described_class.geo_db_path = ''
      expect(described_class.database_loaded?).to be false
      expect(described_class.geo_db_path).to be_nil
    end
  end

  describe '.unload_database! / .database_reader=' do
    it 'drops the in-memory reader' do
      described_class.geo_db_path = fixture_db
      described_class.unload_database!
      expect(described_class.database_loaded?).to be false
    end

    it 'accepts a directly injected reader' do
      described_class.database_reader = reader_returning({ 'country' => { 'iso_code' => 'SE' } })
      expect(described_class.database_loaded?).to be true
      expect(described_class.resolve('9.9.9.9', {})).to eq('SE')
    end
  end

  describe '.reset!' do
    it 'clears every boot-time setting' do
      described_class.custom_resolver = ->(_ip, _env) { 'US' }
      described_class.geo_header = 'X-Client-Country'
      described_class.geo_db_path = fixture_db

      described_class.reset!

      expect(described_class.custom_resolver).to be_nil
      expect(described_class.geo_header).to be_nil
      expect(described_class.database_loaded?).to be false
    end
  end
end
