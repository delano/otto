# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'IP Privacy Features' do
  describe Otto::Privacy::IPPrivacy do
    describe '.mask_ip' do
      context 'IPv4 addresses' do
        it 'masks last octet with level 1' do
          expect(Otto::Privacy::IPPrivacy.mask_ip('192.168.1.100', 1)).to eq('192.168.1.0')
        end

        it 'masks last 2 octets with level 2' do
          expect(Otto::Privacy::IPPrivacy.mask_ip('192.168.1.100', 2)).to eq('192.168.0.0')
        end

        it 'handles different IP ranges' do
          expect(Otto::Privacy::IPPrivacy.mask_ip('10.20.30.40', 1)).to eq('10.20.30.0')
          expect(Otto::Privacy::IPPrivacy.mask_ip('172.16.50.25', 2)).to eq('172.16.0.0')
        end
      end

      context 'IPv6 addresses' do
        it 'masks last 80 bits with level 1' do
          result = Otto::Privacy::IPPrivacy.mask_ip('2001:0db8:85a3:0000:0000:8a2e:0370:7334', 1)
          expect(result).to match(/^2001:db8:85a3::/)
        end

        it 'masks last 96 bits with level 2' do
          result = Otto::Privacy::IPPrivacy.mask_ip('2001:0db8:85a3:0000:0000:8a2e:0370:7334', 2)
          expect(result).to match(/^2001:db8::/)
        end
      end

      context 'error handling' do
        it 'raises ArgumentError for invalid level' do
          expect { Otto::Privacy::IPPrivacy.mask_ip('192.168.1.1', 3) }
            .to raise_error(ArgumentError, /Masking level must be 1 or 2/)
        end

        it 'raises ArgumentError for invalid IP' do
          expect { Otto::Privacy::IPPrivacy.mask_ip('not-an-ip', 1) }
            .to raise_error(ArgumentError, /Invalid IP address/)
        end

        it 'returns nil for nil input' do
          expect(Otto::Privacy::IPPrivacy.mask_ip(nil, 1)).to be_nil
        end

        it 'returns nil for empty string' do
          expect(Otto::Privacy::IPPrivacy.mask_ip('', 1)).to be_nil
        end
      end
    end

    describe '.hash_ip' do
      it 'creates consistent hash for same IP and key' do
        key = 'test-key'
        hash1 = Otto::Privacy::IPPrivacy.hash_ip('192.168.1.100', key)
        hash2 = Otto::Privacy::IPPrivacy.hash_ip('192.168.1.100', key)

        expect(hash1).to eq(hash2)
      end

      it 'creates different hashes for different IPs' do
        key = 'test-key'
        hash1 = Otto::Privacy::IPPrivacy.hash_ip('192.168.1.100', key)
        hash2 = Otto::Privacy::IPPrivacy.hash_ip('192.168.1.101', key)

        expect(hash1).not_to eq(hash2)
      end

      it 'creates different hashes for different keys' do
        hash1 = Otto::Privacy::IPPrivacy.hash_ip('192.168.1.100', 'key1')
        hash2 = Otto::Privacy::IPPrivacy.hash_ip('192.168.1.100', 'key2')

        expect(hash1).not_to eq(hash2)
      end

      it 'returns 64-character hex string' do
        hash = Otto::Privacy::IPPrivacy.hash_ip('192.168.1.100', 'test-key')

        expect(hash).to match(/^[0-9a-f]{64}$/)
      end

      it 'raises ArgumentError for nil key' do
        expect { Otto::Privacy::IPPrivacy.hash_ip('192.168.1.1', nil) }
          .to raise_error(ArgumentError, /Key cannot be nil/)
      end
    end

    describe '.valid_ip?' do
      it 'returns true for valid IPv4' do
        expect(Otto::Privacy::IPPrivacy.valid_ip?('192.168.1.1')).to be true
      end

      it 'returns true for valid IPv6' do
        expect(Otto::Privacy::IPPrivacy.valid_ip?('2001:0db8:85a3::8a2e:0370:7334')).to be true
      end

      it 'returns false for invalid IP' do
        expect(Otto::Privacy::IPPrivacy.valid_ip?('not-an-ip')).to be false
      end

      it 'returns false for nil' do
        expect(Otto::Privacy::IPPrivacy.valid_ip?(nil)).to be false
      end
    end
  end

  describe Otto::Privacy::GeoResolver do
    describe '.resolve' do
      it 'uses CloudFlare header when available' do
        env = { 'HTTP_CF_IPCOUNTRY' => 'US' }
        result = Otto::Privacy::GeoResolver.resolve('1.2.3.4', env)

        expect(result).to eq('US')
      end

      it 'returns XX for unknown IP' do
        result = Otto::Privacy::GeoResolver.resolve('1.2.3.4', {})

        expect(result).to eq('XX')
      end

      it 'detects Google DNS as US' do
        result = Otto::Privacy::GeoResolver.resolve('8.8.8.8', {})

        expect(result).to eq('US')
      end

      it 'ignores invalid CloudFlare header' do
        env = { 'HTTP_CF_IPCOUNTRY' => 'invalid' }
        result = Otto::Privacy::GeoResolver.resolve('1.2.3.4', env)

        expect(result).to eq('XX')
      end

      it 'returns XX for private IPs' do
        result = Otto::Privacy::GeoResolver.resolve('192.168.1.1', {})

        expect(result).to eq('XX')
      end
    end
  end

  describe Otto::Privacy::PrivateFingerprint do
    let(:config) { Otto::Privacy::Config.new }
    let(:env) do
      {
        'REMOTE_ADDR' => '192.168.1.100',
        'HTTP_USER_AGENT' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        'PATH_INFO' => '/test',
        'REQUEST_METHOD' => 'GET',
        'HTTP_REFERER' => 'https://example.com/page?param=value'
      }
    end

    it 'creates fingerprint with masked IP' do
      fingerprint = Otto::Privacy::PrivateFingerprint.new(env, config)

      expect(fingerprint.masked_ip).to eq('192.168.1.0')
    end

    it 'creates fingerprint with hashed IP' do
      fingerprint = Otto::Privacy::PrivateFingerprint.new(env, config)

      expect(fingerprint.hashed_ip).to match(/^[0-9a-f]{64}$/)
    end

    it 'anonymizes user agent' do
      fingerprint = Otto::Privacy::PrivateFingerprint.new(env, config)

      expect(fingerprint.anonymized_ua).to include('X.X')
      expect(fingerprint.anonymized_ua).not_to include('10.0')
    end

    it 'anonymizes referer' do
      fingerprint = Otto::Privacy::PrivateFingerprint.new(env, config)

      expect(fingerprint.referer).to eq('https://example.com/page')
      expect(fingerprint.referer).not_to include('param')
    end

    it 'includes request details' do
      fingerprint = Otto::Privacy::PrivateFingerprint.new(env, config)

      expect(fingerprint.request_path).to eq('/test')
      expect(fingerprint.request_method).to eq('GET')
    end

    it 'is frozen after creation' do
      fingerprint = Otto::Privacy::PrivateFingerprint.new(env, config)

      expect(fingerprint).to be_frozen
    end

    it 'converts to hash' do
      fingerprint = Otto::Privacy::PrivateFingerprint.new(env, config)
      hash = fingerprint.to_h

      expect(hash).to include(:masked_ip, :hashed_ip, :anonymized_ua)
    end
  end

  describe Otto::Security::Middleware::IPPrivacyMiddleware do
    let(:app) { ->(env) { [200, {}, ['OK']] } }
    let(:security_config) { Otto::Security::Config.new }
    let(:middleware) { Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config) }

    context 'privacy enabled (default)' do
      it 'masks IP address by default' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['REMOTE_ADDR']).to eq('192.168.1.0')
      end

      it 'sets private fingerprint' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['otto.private_fingerprint']).to be_a(Otto::Privacy::PrivateFingerprint)
      end

      it 'sets masked IP' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['otto.masked_ip']).to eq('192.168.1.0')
      end

      it 'does not set original IP' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['otto.original_ip']).to be_nil
      end
    end

    context 'privacy disabled' do
      before do
        security_config.ip_privacy_config.disable!
      end

      it 'preserves original IP' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['REMOTE_ADDR']).to eq('192.168.1.100')
      end

      it 'sets original IP for reference' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['otto.original_ip']).to eq('192.168.1.100')
      end

      it 'does not create private fingerprint' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['otto.private_fingerprint']).to be_nil
      end
    end
  end

  describe 'Otto integration' do
    let(:routes_file) { create_test_routes_file('ip_privacy_routes.txt', ['GET / TestApp.index']) }

    it 'enables IP privacy by default' do
      otto = Otto.new(routes_file)

      expect(otto.security_config.ip_privacy_config.enabled?).to be true
    end

    it 'includes IPPrivacyMiddleware in stack' do
      otto = Otto.new(routes_file)

      expect(otto.middleware.includes?(Otto::Security::Middleware::IPPrivacyMiddleware)).to be true
    end

    it 'allows disabling IP privacy' do
      otto = create_minimal_otto(['GET / TestApp.index'])
      otto.disable_ip_privacy!

      expect(otto.security_config.ip_privacy_config.disabled?).to be true
    end

    it 'allows configuring mask level' do
      otto = create_minimal_otto(['GET / TestApp.index'])
      otto.configure_ip_privacy(mask_level: 2)

      expect(otto.security_config.ip_privacy_config.mask_level).to eq(2)
    end
  end
end
