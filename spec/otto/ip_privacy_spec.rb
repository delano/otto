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
      context 'public IP addresses' do
        it 'masks public IP addresses' do
          env = { 'REMOTE_ADDR' => '8.8.8.8' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('8.8.8.0')
        end

        it 'sets private fingerprint for public IPs' do
          env = { 'REMOTE_ADDR' => '8.8.8.8' }
          middleware.call(env)

          expect(env['otto.private_fingerprint']).to be_a(Otto::Privacy::PrivateFingerprint)
        end

        it 'sets masked IP for public IPs' do
          env = { 'REMOTE_ADDR' => '8.8.8.8' }
          middleware.call(env)

          expect(env['otto.masked_ip']).to eq('8.8.8.0')
        end

        it 'does not set original IP for public IPs' do
          env = { 'REMOTE_ADDR' => '8.8.8.8' }
          middleware.call(env)

          expect(env['otto.original_ip']).to be_nil
        end
      end

      context 'encoding of masked IPs' do
        it 'ensures masked IP has UTF-8 encoding' do
          env = { 'REMOTE_ADDR' => '127.0.0.1' }
          middleware.call(env)

          expect(env['REMOTE_ADDR'].encoding).to eq(Encoding::UTF_8)
        end

        it 'does not set original IP when privacy enabled' do
          env = { 'REMOTE_ADDR' => '127.0.0.1' }
          middleware.call(env)

          expect(env['otto.original_ip']).to be_nil
        end
      end

      context.skip 'private/localhost IP addresses privatization is disabled by default' do
        it 'does not mask localhost (127.0.0.1)' do
          env = { 'REMOTE_ADDR' => '127.0.0.1' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('127.0.0.1')
          expect(env['otto.original_ip']).to eq('127.0.0.1')
        end

        it 'does not mask private IPs (192.168.x.x)' do
          env = { 'REMOTE_ADDR' => '192.168.1.100' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('192.168.1.100')
          expect(env['otto.original_ip']).to eq('192.168.1.100')
        end

        it 'does not mask private IPs (10.x.x.x)' do
          env = { 'REMOTE_ADDR' => '10.0.0.5' }
          middleware.call(env)

          expect(env['REMOTE_ADDR']).to eq('10.0.0.5')
          expect(env['otto.original_ip']).to eq('10.0.0.5')
        end

        it 'does not create fingerprint for private IPs' do
          env = { 'REMOTE_ADDR' => '192.168.1.100' }
          middleware.call(env)

          expect(env['otto.private_fingerprint']).to be_nil

        end
      end

      context 'private/localhost IP addresses' do
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
  end

  describe 'Rack::Request#ip integration' do
    let(:app) { ->(env) { [200, {}, ['OK']] } }
    let(:security_config) { Otto::Security::Config.new }
    let(:middleware) { Otto::Security::Middleware::IPPrivacyMiddleware.new(app, security_config) }

    context 'with privacy enabled' do
      it 'Rack::Request#ip returns masked IP' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('192.168.1.0')
      end

      it 'works with CommonLogger-style IP access' do
        env = { 'REMOTE_ADDR' => '8.8.8.8' }
        middleware.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('8.8.8.0')
      end

      it 'masks localhost IPs' do
        env = { 'REMOTE_ADDR' => '127.0.0.1' }
        middleware.call(env)

        request = Rack::Request.new(env)
        expect(request.ip).to eq('127.0.0.0')
      end

      it 'provides consistent IP across multiple request instances' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }
        middleware.call(env)

        request1 = Rack::Request.new(env)
        request2 = Rack::Request.new(env)

        expect(request1.ip).to eq('192.168.1.0')
        expect(request2.ip).to eq('192.168.1.0')
      end

      it 'does not cache original IP in request memoization' do
        env = { 'REMOTE_ADDR' => '192.168.1.100' }

        # Create request BEFORE middleware runs
        request = Rack::Request.new(env)

        # Run middleware to mask IP
        middleware.call(env)

        # Request should return masked IP even though it was created first
        # (This tests that we're not relying on @ip memoization)
        expect(request.ip).to eq('192.168.1.0')
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
      it 'masks IP through complete middleware chain' do
        otto = Otto.new(routes_file)

        env = {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/',
          'REMOTE_ADDR' => '192.168.1.100',
          'rack.input' => StringIO.new
        }

        # Call through the full Otto middleware stack
        status, headers, body = otto.call(env)

        # Verify REMOTE_ADDR was masked
        expect(env['REMOTE_ADDR']).to eq('192.168.1.0')

        # Verify private fingerprint was created
        expect(env['otto.private_fingerprint']).to be_a(Otto::Privacy::PrivateFingerprint)
        expect(env['otto.private_fingerprint'].masked_ip).to eq('192.168.1.0')
      end

      it 'masks IP for all HTTP methods' do
        otto = Otto.new(routes_file)

        %w[GET POST PUT PATCH DELETE].each do |method|
          env = {
            'REQUEST_METHOD' => method,
            'PATH_INFO' => '/',
            'REMOTE_ADDR' => '10.0.0.5',
            'rack.input' => StringIO.new
          }

          otto.call(env)
          expect(env['REMOTE_ADDR']).to eq('10.0.0.0')
        end
      end

      it 'handles multiple requests with different IPs' do
        otto = Otto.new(routes_file)

        ips = ['192.168.1.100', '10.0.0.5', '172.16.0.10', '8.8.8.8']
        expected = ['192.168.1.0', '10.0.0.0', '172.16.0.0', '8.8.8.0']

        ips.zip(expected).each do |original_ip, masked_ip|
          env = {
            'REQUEST_METHOD' => 'GET',
            'PATH_INFO' => '/',
            'REMOTE_ADDR' => original_ip,
            'rack.input' => StringIO.new
          }

          otto.call(env)
          expect(env['REMOTE_ADDR']).to eq(masked_ip)
        end
      end

      it 'creates unique hashed IPs for different IPs' do
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

        expect(hashes[0]).not_to eq(hashes[1])
        expect(hashes[0]).to match(/^[0-9a-f]{64}$/)
        expect(hashes[1]).to match(/^[0-9a-f]{64}$/)
      end

      it 'creates consistent hashed IPs for same IP across requests' do
        otto = Otto.new(routes_file)

        hashes = []
        2.times do
          env = {
            'REQUEST_METHOD' => 'GET',
            'PATH_INFO' => '/',
            'REMOTE_ADDR' => '192.168.1.100',
            'rack.input' => StringIO.new
          }

          otto.call(env)
          hashes << env['otto.hashed_ip']
        end

        expect(hashes[0]).to eq(hashes[1])
      end
    end

    context 'with custom mask level' do
      it 'masks 2 octets when configured' do
        otto = create_minimal_otto(['GET / TestApp.index'])
        otto.configure_ip_privacy(mask_level: 2)

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

  describe 'Rack::CommonLogger compatibility' do
    let(:logged_output) { StringIO.new }
    let(:logger) { Logger.new(logged_output) }

    it 'CommonLogger logs masked IP when privacy enabled' do
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

      # CommonLogger should log the masked IP
      expect(log_line).to include('192.168.1.0')
      expect(log_line).not_to include('192.168.1.100')
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

    it 'CommonLogger logs masked localhost' do
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

      # CommonLogger should log the masked localhost IP
      expect(log_line).to include('127.0.0.0')
      expect(log_line).not_to include('127.0.0.1')
    end
  end
end
