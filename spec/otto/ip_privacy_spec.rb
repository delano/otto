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

      it 'detects Cloud9 in Switzerland' do
        result = Otto::Privacy::GeoResolver.resolve('9.9.9.9', {})

        expect(result).to eq('CH')
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
      context 'public IP addresses' do
        it 'masks public IP addresses' do
          env = { 'REMOTE_ADDR' => '9.9.9.9' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('9.9.9.0')
        end

        it 'sets private fingerprint for public IPs' do
          env = { 'REMOTE_ADDR' => '9.9.9.9' }
          middleware.call(env)

          expect(env['otto.private_fingerprint']).to be_a(Otto::Privacy::PrivateFingerprint)
        end

        it 'sets masked IP for public IPs' do
          env = { 'REMOTE_ADDR' => '9.9.9.9' }
          middleware.call(env)

          expect(env['otto.masked_ip']).to eq('9.9.9.0')
        end

        it 'does not set original IP for public IPs' do
          env = { 'REMOTE_ADDR' => '9.9.9.9' }
          middleware.call(env)

          expect(env['otto.original_ip']).to be_nil
        end
      end

      context 'encoding of masked IPs' do
        it 'ensures masked IP has UTF-8 encoding for public IPs' do
          env = { 'REMOTE_ADDR' => '9.9.9.9' }
          middleware.call(env)

          expect(env['REMOTE_ADDR'].encoding).to eq(Encoding::UTF_8)
        end

        it 'does not set original IP for public IPs when privacy enabled' do
          env = { 'REMOTE_ADDR' => '9.9.9.9' }
          middleware.call(env)

          expect(env['otto.original_ip']).to be_nil
        end

        it 'ensures original IP has UTF-8 encoding for private/localhost IPs' do
          env = { 'REMOTE_ADDR' => '127.0.0.1' }
          middleware.call(env)

          expect(env['REMOTE_ADDR'].encoding).to eq(Encoding::UTF_8)
          expect(env['otto.original_ip'].encoding).to eq(Encoding::UTF_8)
        end
      end

      context 'private/localhost IP addresses (default: NOT masked)' do
        it 'does NOT mask localhost (127.0.0.1)' do
          env = { 'REMOTE_ADDR' => '127.0.0.1' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('127.0.0.1')
          expect(env['otto.original_ip']).to eq('127.0.0.1')
        end

        it 'does NOT mask private IPs (192.168.x.x)' do
          env = { 'REMOTE_ADDR' => '192.168.1.100' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('192.168.1.100')
          expect(env['otto.original_ip']).to eq('192.168.1.100')
        end

        it 'does NOT mask private IPs (10.x.x.x)' do
          env = { 'REMOTE_ADDR' => '10.0.0.5' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('10.0.0.5')
          expect(env['otto.original_ip']).to eq('10.0.0.5')
        end

        it 'does NOT create fingerprint for private IPs' do
          env = { 'REMOTE_ADDR' => '192.168.1.100' }
          middleware.call(env)

          expect(env['otto.private_fingerprint']).to be_nil
          expect(env['otto.masked_ip']).to be_nil
          expect(env['otto.hashed_ip']).to be_nil
        end
      end

      context 'private/localhost IP addresses (with enable_full_ip_privacy!)' do
        before do
          security_config.ip_privacy_config.mask_private_ips = true
        end

        it 'masks localhost (127.0.0.1)' do
          env = { 'REMOTE_ADDR' => '127.0.0.1' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('127.0.0.0')
          expect(env['otto.original_ip']).to be_nil
        end

        it 'masks private IPs (192.168.x.x)' do
          env = { 'REMOTE_ADDR' => '192.168.1.100' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('192.168.1.0')
          expect(env['otto.original_ip']).to be_nil
        end

        it 'masks private IPs (10.x.x.x)' do
          env = { 'REMOTE_ADDR' => '10.0.0.5' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('10.0.0.0')
          expect(env['otto.original_ip']).to be_nil
        end

        it 'creates fingerprint for private IPs' do
          env = { 'REMOTE_ADDR' => '192.168.1.100' }
          middleware.call(env)

          expect(env['otto.private_fingerprint']).to be_a(Otto::Privacy::PrivateFingerprint)
          expect(env['otto.private_fingerprint'].masked_ip).to eq('192.168.1.0')
        end
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

      it 'ensures original IP has UTF-8 encoding' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['otto.original_ip'].encoding).to eq(Encoding::UTF_8)
      end

      it 'ensures REMOTE_ADDR has UTF-8 encoding' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        expect(env['REMOTE_ADDR'].encoding).to eq(Encoding::UTF_8)
      end
    end
  end

  describe 'Otto integration' do
    let(:routes_file) { create_test_routes_file('ip_privacy_routes.txt', ['GET / TestApp.index']) }

    it 'enables IP privacy by default' do
      otto = Otto.new(routes_file)

      expect(otto.security_config.ip_privacy_config.enabled?).to be true
    end

    it 'includes IPPrivacyMiddleware in stack by default' do
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

    it 'allows enabling full IP privacy (mask private/localhost)' do
      otto = create_minimal_otto(['GET / TestApp.index'])
      otto.enable_full_ip_privacy!

      expect(otto.security_config.ip_privacy_config.mask_private_ips).to be true
    end

    context 'with enable_full_ip_privacy!' do
      it 'masks localhost IP (127.0.0.1) when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '127.0.0.1',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['REMOTE_ADDR']).to eq('127.0.0.0')
        expect(env['otto.original_ip']).to be_nil
        expect(env['otto.masked_ip']).to eq('127.0.0.0')
      end

      it 'masks IPv6 localhost (::1) when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '::1',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['REMOTE_ADDR']).to match(/^::$/)
        expect(env['otto.original_ip']).to be_nil
      end

      it 'masks private IP (192.168.x.x) when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '192.168.1.100',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['REMOTE_ADDR']).to eq('192.168.1.0')
        expect(env['otto.original_ip']).to be_nil
        expect(env['otto.masked_ip']).to eq('192.168.1.0')
      end

      it 'masks private IP (10.x.x.x) when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '10.0.0.5',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['REMOTE_ADDR']).to eq('10.0.0.0')
        expect(env['otto.original_ip']).to be_nil
        expect(env['otto.masked_ip']).to eq('10.0.0.0')
      end

      it 'masks private IP (172.16.x.x) when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '172.16.0.10',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['REMOTE_ADDR']).to eq('172.16.0.0')
        expect(env['otto.original_ip']).to be_nil
        expect(env['otto.masked_ip']).to eq('172.16.0.0')
      end

      it 'creates private fingerprint for localhost when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '127.0.0.1',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['otto.private_fingerprint']).to be_a(Otto::Privacy::PrivateFingerprint)
        expect(env['otto.private_fingerprint'].masked_ip).to eq('127.0.0.0')
        expect(env['otto.hashed_ip']).to match(/^[0-9a-f]{64}$/)
      end

      it 'creates private fingerprint for private IPs when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '192.168.1.100',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['otto.private_fingerprint']).to be_a(Otto::Privacy::PrivateFingerprint)
        expect(env['otto.private_fingerprint'].masked_ip).to eq('192.168.1.0')
        expect(env['otto.hashed_ip']).to match(/^[0-9a-f]{64}$/)
      end

      it 'still masks public IPs when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '9.9.9.9',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['REMOTE_ADDR']).to eq('9.9.9.0')
        expect(env['otto.original_ip']).to be_nil
        expect(env['otto.masked_ip']).to eq('9.9.9.0')
      end

      it 'applies custom mask_level with full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.configure_ip_privacy(mask_level: 2)
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '192.168.1.100',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        expect(env['REMOTE_ADDR']).to eq('192.168.0.0')
        expect(env['otto.masked_ip']).to eq('192.168.0.0')
      end

      it 'Rack::Request#ip returns masked private IP when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '192.168.1.100',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('192.168.1.0')
      end

      it 'Rack::Request#ip returns masked localhost when full privacy enabled' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.enable_full_ip_privacy!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '127.0.0.1',
          'rack.input' => StringIO.new
        }

        otto.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('127.0.0.0')
      end
    end
  end

  describe 'Rack::Request#ip integration' do
    let(:app) { ->(env) { [200, {}, ['OK']] } }
    let(:security_config) { Otto::Security::Config.new }
    let(:middleware) { Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config) }

    context 'with privacy enabled' do
      it 'Rack::Request#ip returns original IP for private addresses' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('192.168.1.100')
      end

      it 'works with CommonLogger-style IP access' do
        env = { 'REMOTE_ADDR' => '9.9.9.9' }
        middleware.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('9.9.9.0')
      end

      it 'does NOT mask localhost IPs' do
        env = { 'REMOTE_ADDR' => '127.0.0.1' }
        middleware.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('127.0.0.1')
      end

      it 'provides consistent IP across multiple request instances' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        request1 = Rack::Request.new(env)
        request2 = Rack::Request.new(env)

        expect(request1.ip).to eq('192.168.1.100')
        expect(request2.ip).to eq('192.168.1.100')
      end

      it 'does not cache original IP in request memoization' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }

        # Create request BEFORE middleware runs
        request = Rack::Request.new(env)

        # Run middleware (private IP won't be masked)
        middleware.call(env)

        # Request should return private IP unchanged
        expect(request.ip).to eq('192.168.1.100')
      end
    end

    context 'with privacy disabled' do
      before do
        security_config.ip_privacy_config.disable!
      end

      it 'Rack::Request#ip returns original IP' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('192.168.1.100')
      end
    end
  end

  describe 'Full middleware stack integration' do
    let(:routes_file) { create_test_routes_file('integration_routes.txt', ['GET / TestApp.index']) }

    context 'with privacy enabled (default)' do
      it 'does NOT mask private IPs through complete middleware chain' do
        otto = Otto.new(routes_file)

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '192.168.1.100',
          'rack.input' => StringIO.new
        }

        # Call through the full Otto middleware stack
        status, headers, body = otto.call(env)

        # Verify REMOTE_ADDR was NOT masked (private IP exemption)
        expect(env['REMOTE_ADDR']).to eq('192.168.1.100')

        # Verify private fingerprint was NOT created
        expect(env['otto.private_fingerprint']).to be_nil
        expect(env['otto.original_ip']).to eq('192.168.1.100')
      end

      it 'does NOT mask private IPs for all HTTP methods' do
        otto = Otto.new(routes_file)

        %w[GET POST PUT PATCH DELETE].each do |method|
          env = {
            'REQUEST_METHOD' => method,
            'PATH_INFO' => '/',
            'REMOTE_ADDR' => '10.0.0.5',
            'rack.input' => StringIO.new
          }

          otto.call(env)
          expect(env['REMOTE_ADDR']).to eq('10.0.0.5')
        end
      end

      it 'handles multiple requests with different IPs (private exempted, public masked)' do
        otto = Otto.new(routes_file)

        ips = ['192.168.1.100', '10.0.0.5', '172.16.0.10', '9.9.9.9']
        expected = ['192.168.1.100', '10.0.0.5', '172.16.0.10', '9.9.9.0']  # Only public IP masked

        ips.zip(expected).each do |original_ip, expected_ip|
          env = {
            'REQUEST_METHOD' => 'GET',
            'PATH_INFO' => '/',
            'REMOTE_ADDR' => original_ip,
            'rack.input' => StringIO.new
          }

          otto.call(env)
          expect(env['REMOTE_ADDR']).to eq(expected_ip)
        end
      end

      it 'does NOT create hashed IPs for private addresses' do
        otto = Otto.new(routes_file)

        hashes = []
        ['192.168.1.100', '192.168.1.101'].each do |ip|
          env = {
            'REQUEST_METHOD' => 'GET',
            'PATH_INFO' => '/',
            'REMOTE_ADDR' => ip,
            'rack.input' => StringIO.new
          }

          otto.call(env)
          hashes << env['otto.hashed_ip']
        end

        # Private IPs are not hashed
        expect(hashes[0]).to be_nil
        expect(hashes[1]).to be_nil
      end

      it 'creates consistent hashed IPs for same PUBLIC IP across requests' do
        otto = Otto.new(routes_file)

        hashes = []
        2.times do
          env = {
            'REQUEST_METHOD' => 'GET',
            'PATH_INFO' => '/',
            'REMOTE_ADDR' => '9.9.9.9',  # Use public IP
            'rack.input' => StringIO.new
          }

          otto.call(env)
          hashes << env['otto.hashed_ip']
        end

        expect(hashes[0]).to eq(hashes[1])
        expect(hashes[0]).to match(/^[0-9a-f]{64}$/)
      end
    end

    context 'with custom mask level' do
      it 'masks 2 octets when configured (PUBLIC IP)' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.configure_ip_privacy(mask_level: 2)

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '9.9.9.9',  # Use public IP
          'rack.input' => StringIO.new
        }

        otto.call(env)
        expect(env['REMOTE_ADDR']).to eq('9.9.0.0')
        expect(env['otto.masked_ip']).to eq('9.9.0.0')
      end
    end

    context 'with privacy disabled' do
      it 'preserves original IP through full stack' do
        otto = create_minimal_otto(['GET / TestApp.index'])

        # Unfreeze to allow configuration changes in test
        Otto.unfreeze_for_testing(otto)
        otto.disable_ip_privacy!

        # Rebuild the middleware app after configuration change
        otto.build_app!

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '192.168.1.100',
          'rack.input' => StringIO.new
        }

        otto.call(env)
        expect(env['REMOTE_ADDR']).to eq('192.168.1.100')
        expect(env['otto.original_ip']).to eq('192.168.1.100')
        expect(env['otto.private_fingerprint']).to be_nil
      end
    end
  end

  describe 'IP Hashing Rotation Key Management' do
    describe 'in-memory rotation keys' do
      let(:config) { Otto::Privacy::Config.new(hash_rotation_period: 3600) }

      it 'generates consistent key within rotation period' do
        key1 = config.rotation_key
        key2 = config.rotation_key

        expect(key1).to eq(key2)
        expect(key1).to match(/^[0-9a-f]{64}$/)
      end

      it 'stores keys at class level (survives config freezing)' do
        config1 = Otto::Privacy::Config.new(hash_rotation_period: 3600)
        key1 = config1.rotation_key
        config1.freeze

        config2 = Otto::Privacy::Config.new(hash_rotation_period: 3600)
        key2 = config2.rotation_key

        # Keys should be shared across instances via class-level storage
        expect(key1).to eq(key2)
      end

      it 'clears old keys when rotation occurs' do
        # Clear existing keys first to ensure clean state
        Otto::Privacy::Config.rotation_keys_store.clear

        config = Otto::Privacy::Config.new(hash_rotation_period: 1)

        key1 = config.rotation_key
        sleep(1.1)  # Wait for rotation period to pass
        key2 = config.rotation_key

        # Different rotation periods should have different keys
        expect(key1).not_to eq(key2)

        # Store should have at most 2 keys (current + previous for boundary wiggle room)
        store = Otto::Privacy::Config.rotation_keys_store
        expect(store.size).to be <= 2
      end
    end

    describe 'Redis-based rotation keys' do
      let(:redis) { double('Redis') }
      let(:config) { Otto::Privacy::Config.new(hash_rotation_period: 3600, redis: redis) }

      before do
        allow(Time).to receive(:now).and_return(Time.utc(2025, 1, 15, 12, 0, 0))
      end

      it 'uses SET NX GET EX for atomic key generation' do
        rotation_timestamp = 1736942400  # 2025-01-15 12:00:00 UTC quantized to hour
        redis_key = "rotation_key:#{rotation_timestamp}"
        ttl = (3600 * 1.2).to_i  # 4320 seconds (20% buffer)

        # Simulate key doesn't exist (first server to request it)
        expect(redis).to receive(:set).with(
          redis_key,
          instance_of(String),
          nx: true,
          get: true,
          ex: ttl
        ).and_return(nil)

        key = config.rotation_key

        expect(key).to match(/^[0-9a-f]{64}$/)
      end

      it 'returns existing key when already set' do
        rotation_timestamp = 1736942400
        redis_key = "rotation_key:#{rotation_timestamp}"
        existing_key = 'a' * 64

        # Simulate key already exists (another server set it)
        expect(redis).to receive(:set).and_return(existing_key)

        key = config.rotation_key

        expect(key).to eq(existing_key)
      end

      it 'generates different keys for different rotation periods' do
        keys = []

        # First period: 12:00:00
        allow(Time).to receive(:now).and_return(Time.utc(2025, 1, 15, 12, 0, 0))
        expect(redis).to receive(:set).and_return(nil)
        keys << config.rotation_key

        # Second period: 13:00:00
        allow(Time).to receive(:now).and_return(Time.utc(2025, 1, 15, 13, 0, 0))
        expect(redis).to receive(:set).and_return(nil)
        keys << config.rotation_key

        expect(keys[0]).not_to eq(keys[1])
      end

      it 'uses correct TTL with 20% buffer' do
        rotation_timestamp = 1736942400
        redis_key = "rotation_key:#{rotation_timestamp}"

        config_2h = Otto::Privacy::Config.new(hash_rotation_period: 7200, redis: redis)

        allow(Time).to receive(:now).and_return(Time.utc(2025, 1, 15, 12, 0, 0))

        expect(redis).to receive(:set).with(
          anything,
          anything,
          hash_including(ex: (7200 * 1.2).to_i)
        ).and_return(nil)

        config_2h.rotation_key
      end

      it 'quantizes timestamp to rotation period boundary' do
        config = Otto::Privacy::Config.new(hash_rotation_period: 3600, redis: redis)

        # All times within same hour should use same Redis key
        times = [
          Time.utc(2025, 1, 15, 12, 0, 0),
          Time.utc(2025, 1, 15, 12, 30, 0),
          Time.utc(2025, 1, 15, 12, 59, 59)
        ]

        expected_key = 'rotation_key:1736942400'  # 12:00:00 boundary

        times.each do |time|
          allow(Time).to receive(:now).and_return(time)
          expect(redis).to receive(:set).with(
            expected_key,
            anything,
            anything
          ).and_return(nil)

          config.rotation_key
        end
      end
    end

    describe 'configuration freezing' do
      it 'rotation keys remain accessible after config is frozen' do
        config = Otto::Privacy::Config.new(hash_rotation_period: 3600)

        key_before = config.rotation_key
        config.freeze
        key_after = config.rotation_key

        expect(key_before).to eq(key_after)
        expect(config).to be_frozen
      end

      it 'class-level store remains mutable when instances are frozen' do
        config1 = Otto::Privacy::Config.new(hash_rotation_period: 3600)
        config1.freeze

        config2 = Otto::Privacy::Config.new(hash_rotation_period: 3600)

        # Both should be able to generate/access keys
        expect { config1.rotation_key }.not_to raise_error
        expect { config2.rotation_key }.not_to raise_error
      end
    end

    describe 'thread safety' do
      it 'handles concurrent rotation key access without race conditions' do
        config = Otto::Privacy::Config.new(hash_rotation_period: 3600)
        keys = Concurrent::Array.new

        threads = 10.times.map do
          Thread.new do
            100.times do
              keys << config.rotation_key
            end
          end
        end

        threads.each(&:join)

        # All keys within same rotation period should be identical
        expect(keys.uniq.size).to eq(1)
      end

      it 'handles concurrent rotation key access during rotation boundary' do
        keys = Concurrent::Array.new
        start_time = Time.utc(2025, 1, 15, 12, 59, 59)

        threads = 10.times.map do |i|
          Thread.new do
            config = Otto::Privacy::Config.new(hash_rotation_period: 3600)

            # Simulate requests near rotation boundary
            time_offset = i * 0.2  # Spread across boundary
            allow(Time).to receive(:now).and_return(start_time + time_offset)

            keys << config.rotation_key
          end
        end

        threads.each(&:join)

        # Should have at most 2 different keys (before/after rotation)
        expect(keys.uniq.size).to be <= 2
      end
    end

    describe 'rotation boundary edge cases' do
      let(:config) { Otto::Privacy::Config.new(hash_rotation_period: 3600) }

      it 'handles exact rotation boundary timestamp' do
        # Exactly at rotation boundary: 2025-01-15 12:00:00 UTC
        boundary_time = Time.utc(2025, 1, 15, 12, 0, 0)
        allow(Time).to receive(:now).and_return(boundary_time)

        key = config.rotation_key
        expect(key).to match(/^[0-9a-f]{64}$/)
      end

      it 'generates different keys across rotation boundary' do
        keys = []

        # Just before rotation: 11:59:59
        allow(Time).to receive(:now).and_return(Time.utc(2025, 1, 15, 11, 59, 59))
        keys << config.rotation_key

        # Just after rotation: 12:00:01
        allow(Time).to receive(:now).and_return(Time.utc(2025, 1, 15, 12, 0, 1))
        keys << config.rotation_key

        expect(keys[0]).not_to eq(keys[1])
      end

      it 'maintains consistency within one second of boundary' do
        base_time = Time.utc(2025, 1, 15, 12, 0, 0)
        keys = []

        # Multiple requests within same second at boundary
        5.times do |i|
          allow(Time).to receive(:now).and_return(base_time + (i * 0.1))
          keys << config.rotation_key
        end

        # All should use same key (same rotation period)
        expect(keys.uniq.size).to eq(1)
      end

      it 'handles very short rotation periods correctly' do
        config_60s = Otto::Privacy::Config.new(hash_rotation_period: 60)

        keys = []
        base_time = Time.utc(2025, 1, 15, 12, 0, 0)

        # First minute
        allow(Time).to receive(:now).and_return(base_time)
        keys << config_60s.rotation_key

        # Second minute
        allow(Time).to receive(:now).and_return(base_time + 60)
        keys << config_60s.rotation_key

        # Third minute
        allow(Time).to receive(:now).and_return(base_time + 120)
        keys << config_60s.rotation_key

        # Each minute should have different key
        expect(keys.uniq.size).to eq(3)
      end
    end
  end

  describe 'Rack::CommonLogger compatibility' do
    let(:logged_output) { StringIO.new }
    let(:logger) { Logger.new(logged_output) }

    it 'CommonLogger logs original private IP (not masked by default)' do
      security_config = Otto::Security::Config.new

      # Build middleware stack: CommonLogger wraps IPPrivacyMiddleware
      app = ->(env) { [200, { 'content-type' => 'text/plain' }, ['OK']] }
      privacy_middleware = Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config)
      common_logger = Rack::CommonLogger.new(privacy_middleware, logged_output)

      env = Rack::MockRequest.env_for(
        'http://example.com/',
        'REMOTE_ADDR' => '192.168.1.100'
      )

      status, headers, body = common_logger.call(env)
      body.close if body.respond_to?(:close)

      logged_output.rewind
      log_line = logged_output.read

      # CommonLogger should log the original private IP (not masked)
      expect(log_line).to include('192.168.1.100')
    end

    it 'CommonLogger logs original IP when privacy disabled' do
      security_config = Otto::Security::Config.new
      security_config.ip_privacy_config.disable!

      app = ->(env) { [200, { 'content-type' => 'text/plain' }, ['OK']] }
      privacy_middleware = Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config)
      common_logger = Rack::CommonLogger.new(privacy_middleware, logged_output)

      env = Rack::MockRequest.env_for(
        'http://example.com/',
        'REMOTE_ADDR' => '192.168.1.100'
      )

      status, headers, body = common_logger.call(env)
      body.close if body.respond_to?(:close)

      logged_output.rewind
      log_line = logged_output.read

      # CommonLogger should log the original IP
      expect(log_line).to include('192.168.1.100')
    end

    it 'CommonLogger logs original localhost IP (not masked by default)' do
      security_config = Otto::Security::Config.new

      app = ->(env) { [200, { 'content-type' => 'text/plain' }, ['OK']] }
      privacy_middleware = Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config)
      common_logger = Rack::CommonLogger.new(privacy_middleware, logged_output)

      env = Rack::MockRequest.env_for(
        'http://localhost/',
        'REMOTE_ADDR' => '127.0.0.1'
      )

      status, headers, body = common_logger.call(env)
      body.close if body.respond_to?(:close)

      logged_output.rewind
      log_line = logged_output.read

      # CommonLogger should log the original localhost IP (not masked)
      expect(log_line).to include('127.0.0.1')
    end
  end
end
