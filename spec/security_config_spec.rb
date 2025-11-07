# spec/security_config_spec.rb

# spec/security_config_spec.rb

require 'spec_helper'

RSpec.describe Otto::Security::Config do
  subject(:config) { described_class.new }

  describe 'initialization with safe defaults' do
    it 'disables CSRF protection by default' do
      expect(config.csrf_protection).to be false
      expect(config.csrf_enabled?).to be false
    end

    it 'enables input validation by default' do
      expect(config.input_validation).to be true
    end

    it 'sets reasonable limits for request processing' do
      expect(config.max_request_size).to eq(10 * 1024 * 1024) # 10MB
      expect(config.max_param_depth).to eq(32)
      expect(config.max_param_keys).to eq(64)
    end

    it 'initializes empty trusted proxies list' do
      expect(config.trusted_proxies).to be_empty
    end

    it 'sets secure cookie requirements to false by default' do
      expect(config.require_secure_cookies).to be false
    end

    it 'configures CSRF token keys' do
      expect(config.csrf_token_key).to eq('_csrf_token')
      expect(config.csrf_header_key).to eq('HTTP_X_CSRF_TOKEN')
      expect(config.csrf_session_key).to eq('_csrf_session_id')
    end
  end

  describe 'safe security headers by default' do
    let(:default_headers) { config.security_headers }

    it 'includes only safe headers by default' do
      safe_headers = %w[
        x-content-type-options
        x-xss-protection
        referrer-policy
      ]

      expect(default_headers.keys).to match_array(safe_headers)

      puts "\n=== DEBUG: Default Security Headers ==="
      default_headers.each { |k, v| puts "  #{k}: #{v}" }
      puts "======================================\n"
    end

    it 'excludes dangerous headers by default' do
      dangerous_headers = %w[
        strict-transport-security
        content-security-policy
        x-frame-options
      ]

      dangerous_present = dangerous_headers.select { |h| default_headers.key?(h) }
      expect(dangerous_present).to be_empty
    end

    it 'sets appropriate values for safe headers' do
      expect(default_headers['x-content-type-options']).to eq('nosniff')
      expect(default_headers['x-xss-protection']).to eq('1; mode=block')
      expect(default_headers['referrer-policy']).to eq('strict-origin-when-cross-origin')
    end
  end

  describe 'CSRF protection' do
    describe '#enable_csrf_protection!' do
      it 'enables CSRF protection when called' do
        expect { config.enable_csrf_protection! }
          .to change { config.csrf_enabled? }.from(false).to(true)
      end

      it 'updates the csrf_protection flag' do
        expect { config.enable_csrf_protection! }
          .to change { config.csrf_protection }.from(false).to(true)
      end
    end

    describe '#disable_csrf_protection!' do
      it 'disables CSRF protection when called' do
        config.enable_csrf_protection!
        expect { config.disable_csrf_protection! }
          .to change { config.csrf_enabled? }.from(true).to(false)
      end
    end

    describe 'CSRF token generation and verification' do
      before { config.enable_csrf_protection! }

      it 'generates valid CSRF tokens' do
        token = config.generate_csrf_token
        expect(token).to be_a(String)
        expect(token).to include(':')

        parts = token.split(':')
        expect(parts.length).to eq(2)
        expect(parts[0]).to match(/\A[a-f0-9]{64}\z/) # 32 bytes = 64 hex chars
        expect(parts[1]).to match(/\A[a-f0-9]{64}\z/) # SHA256 = 64 hex chars

        puts "\n=== DEBUG: CSRF Token ==="
        puts "Token: #{token}"
        puts "Token part: #{parts[0]}"
        puts "Signature: #{parts[1]}"
        puts "========================\n"
      end

      it 'generates different tokens on each call' do
        token1 = config.generate_csrf_token
        token2 = config.generate_csrf_token
        expect(token1).not_to eq(token2)
      end

      it 'verifies valid tokens' do
        session_id = 'test_session_123'
        token = config.generate_csrf_token(session_id)

        expect(config.verify_csrf_token(token, session_id)).to be true
      end

      it 'rejects invalid tokens' do
        session_id = 'test_session_123'
        fake_token = 'invalid:token'

        expect(config.verify_csrf_token(fake_token, session_id)).to be false
      end

      it 'rejects tokens from different sessions' do
        session_id1 = 'session_1'
        session_id2 = 'session_2'
        token = config.generate_csrf_token(session_id1)

        expect(config.verify_csrf_token(token, session_id2)).to be false
      end

      it 'rejects nil or empty tokens' do
        expect(config.verify_csrf_token(nil, 'session')).to be false
        expect(config.verify_csrf_token('', 'session')).to be false
        expect(config.verify_csrf_token('   ', 'session')).to be false
      end

      it 'rejects malformed tokens' do
        malformed_tokens = [
          'no_colon_separator',
          'too:many:colons:here',
          ':missing_token_part',
          'missing_signature_part:',
          'short_token:abc',
          'token_part:short_sig',
        ]

        malformed_tokens.each do |token|
          expect(config.verify_csrf_token(token, 'session')).to be(false)
        end
      end
    end
  end

  describe 'trusted proxies' do
    describe '#add_trusted_proxy' do
      it 'accepts string IP addresses' do
        config.add_trusted_proxy('192.168.1.1')
        expect(config.trusted_proxies).to include('192.168.1.1')
      end

      it 'accepts CIDR ranges as strings' do
        config.add_trusted_proxy('10.0.0.0/8')
        expect(config.trusted_proxies).to include('10.0.0.0/8')
      end

      it 'accepts arrays of proxies' do
        proxies = ['192.168.1.1', '10.0.0.0/8', '172.16.0.0/12']
        config.add_trusted_proxy(proxies)
        expect(config.trusted_proxies).to include(*proxies)
      end

      it 'raises error for invalid proxy types' do
        expect { config.add_trusted_proxy(123) }
          .to raise_error(ArgumentError, /Proxy must be a String, Regexp, or Array/)
      end
    end

    describe '#trusted_proxy?' do
      before do
        config.add_trusted_proxy(['192.168.1.1', '10.0.0.0/8'])
      end

      it 'returns false when no trusted proxies configured' do
        empty_config = described_class.new
        expect(empty_config.trusted_proxy?('192.168.1.1')).to be false
      end

      it 'identifies exact IP matches' do
        expect(config.trusted_proxy?('192.168.1.1')).to be true
        expect(config.trusted_proxy?('192.168.1.2')).to be false
      end

      it 'identifies CIDR range matches using string prefix matching' do
        # The implementation uses simple string prefix matching, not proper CIDR
        # '10.0.0.1'.start_with?('10.0.0.0/8') is false since it doesn't literally start with that string
        expect(config.trusted_proxy?('10.0.0.0/8')).to be true # Exact match with CIDR
        expect(config.trusted_proxy?('10.0.0.0/8123')).to be true # Starts with CIDR string
        expect(config.trusted_proxy?('10.0.0.1')).to be false # Different IP that doesn't start with proxy string
        expect(config.trusted_proxy?('11.0.0.1')).to be false
      end

      it 'handles string matching for network ranges' do
        config.add_trusted_proxy('172.16.')
        expect(config.trusted_proxy?('172.16.1.1')).to be true
        expect(config.trusted_proxy?('172.17.1.1')).to be false
      end
    end
  end

  describe 'request size validation' do
    describe '#validate_request_size' do
      it 'accepts requests within size limit' do
        expect(config.validate_request_size('1024')).to be true
        expect(config.validate_request_size(1024)).to be true
      end

      it 'accepts nil content length' do
        expect(config.validate_request_size(nil)).to be true
      end

      it 'rejects oversized requests' do
        oversized = config.max_request_size + 1
        expect { config.validate_request_size(oversized.to_s) }
          .to raise_error(Otto::Security::RequestTooLargeError) do |error|
            expect(error.message).to include("exceeds maximum #{config.max_request_size}")
            puts "\n=== DEBUG: Request Size Error ==="
            puts "Error: #{error.message}"
            puts "Max size: #{config.max_request_size}"
            puts "Attempted size: #{oversized}"
            puts "===============================\n"
          end
      end

      it 'handles string content lengths' do
        expect { config.validate_request_size('999999999999') }
          .to raise_error(Otto::Security::RequestTooLargeError)
      end
    end
  end

  describe 'explicit security header enabling' do
    describe '#enable_hsts!' do
      it 'adds HSTS header with default values' do
        config.enable_hsts!
        hsts_header = config.security_headers['strict-transport-security']

        expect(hsts_header).to eq('max-age=31536000; includeSubDomains')

        puts "\n=== DEBUG: HSTS Header ==="
        puts "HSTS Value: #{hsts_header}"
        puts "=========================\n"
      end

      it 'accepts custom HSTS options' do
        config.enable_hsts!(max_age: 86_400, include_subdomains: false)
        hsts_header = config.security_headers['strict-transport-security']

        expect(hsts_header).to eq('max-age=86400')
      end

      it 'overwrites previous HSTS settings' do
        config.enable_hsts!(max_age: 3600, include_subdomains: true)
        config.enable_hsts!(max_age: 7200, include_subdomains: false)

        hsts_header = config.security_headers['strict-transport-security']
        expect(hsts_header).to eq('max-age=7200')
      end
    end

    describe '#enable_csp!' do
      it 'adds CSP header with default policy' do
        config.enable_csp!
        csp_header = config.security_headers['content-security-policy']

        expect(csp_header).to eq("default-src 'self'")

        puts "\n=== DEBUG: CSP Header ==="
        puts "CSP Value: #{csp_header}"
        puts "========================\n"
      end

      it 'accepts custom CSP policy' do
        custom_policy = "default-src 'self'; script-src 'self' 'unsafe-inline'"
        config.enable_csp!(custom_policy)

        csp_header = config.security_headers['content-security-policy']
        expect(csp_header).to eq(custom_policy)
      end

      it 'overwrites previous CSP settings' do
        config.enable_csp!("default-src 'none'")
        config.enable_csp!("default-src 'self'")

        csp_header = config.security_headers['content-security-policy']
        expect(csp_header).to eq("default-src 'self'")
      end
    end

    describe '#enable_frame_protection!' do
      it 'adds X-Frame-Options header with default value' do
        config.enable_frame_protection!
        frame_header = config.security_headers['x-frame-options']

        expect(frame_header).to eq('SAMEORIGIN')

        puts "\n=== DEBUG: Frame Protection Header ==="
        puts "X-Frame-Options Value: #{frame_header}"
        puts "====================================\n"
      end

      it 'accepts custom frame protection options' do
        config.enable_frame_protection!('DENY')
        frame_header = config.security_headers['x-frame-options']

        expect(frame_header).to eq('DENY')
      end

      it 'accepts ALLOW-FROM directive' do
        config.enable_frame_protection!('ALLOW-FROM https://example.com')
        frame_header = config.security_headers['x-frame-options']

        expect(frame_header).to eq('ALLOW-FROM https://example.com')
      end
    end
  end

  describe 'custom security headers' do
    describe '#set_custom_headers' do
      it 'merges custom headers with existing ones' do
        original_count = config.security_headers.size

        custom_headers = {
          'permissions-policy' => 'geolocation=(), microphone=()',
          'cross-origin-opener-policy' => 'same-origin',
        }

        config.set_custom_headers(custom_headers)

        expect(config.security_headers.size).to eq(original_count + 2)
        expect(config.security_headers['permissions-policy']).to eq('geolocation=(), microphone=()')
        expect(config.security_headers['cross-origin-opener-policy']).to eq('same-origin')

        puts "\n=== DEBUG: Custom Headers ==="
        custom_headers.each { |k, v| puts "  #{k}: #{v}" }
        puts "============================\n"
      end

      it 'overwrites existing headers' do
        config.set_custom_headers({ 'x-content-type-options' => 'custom-value' })

        expect(config.security_headers['x-content-type-options']).to eq('custom-value')
      end

      it 'preserves existing headers not being overwritten' do
        original_referrer = config.security_headers['referrer-policy']
        config.set_custom_headers({ 'new-header' => 'new-value' })

        expect(config.security_headers['referrer-policy']).to eq(original_referrer)
        expect(config.security_headers['new-header']).to eq('new-value')
      end
    end
  end

  describe 'configuration isolation' do
    it 'maintains separate configurations for different instances' do
      config1 = described_class.new
      config2 = described_class.new

      config1.enable_csrf_protection!
      config1.enable_hsts!
      config1.add_trusted_proxy('192.168.1.1')

      expect(config1.csrf_enabled?).to be true
      expect(config2.csrf_enabled?).to be false

      expect(config1.security_headers).to have_key('strict-transport-security')
      expect(config2.security_headers).not_to have_key('strict-transport-security')

      expect(config1.trusted_proxies).to include('192.168.1.1')
      expect(config2.trusted_proxies).to be_empty

      puts "\n=== DEBUG: Configuration Isolation ==="
      puts "Config1 CSRF: #{config1.csrf_enabled?}"
      puts "Config2 CSRF: #{config2.csrf_enabled?}"
      puts "Config1 headers: #{config1.security_headers.keys.join(', ')}"
      puts "Config2 headers: #{config2.security_headers.keys.join(', ')}"
      puts "===================================\n"
    end
  end

  describe 'security edge cases' do
    describe 'secure comparison' do
      it 'uses constant-time comparison for CSRF tokens' do
        # We can't directly test timing, but we can test correctness
        session_id = 'test_session'
        valid_token = config.generate_csrf_token(session_id)

        # Test with modified tokens
        parts = valid_token.split(':')
        modified_token = "#{parts[0]}:#{parts[1][0..-2]}x" # Change last char

        expect(config.verify_csrf_token(valid_token, session_id)).to be true
        expect(config.verify_csrf_token(modified_token, session_id)).to be false
      end
    end

    describe 'parameter limits' do
      it 'allows modification of security limits' do
        config.max_request_size = 1024
        config.max_param_depth = 5
        config.max_param_keys = 10

        expect(config.max_request_size).to eq(1024)
        expect(config.max_param_depth).to eq(5)
        expect(config.max_param_keys).to eq(10)

        expect { config.validate_request_size('2048') }
          .to raise_error(Otto::Security::RequestTooLargeError)
      end
    end
  end

  describe 'backward compatibility' do
    it 'maintains safe defaults that do not break existing applications' do
      # Verify that a default config would not break an existing app
      expect(config.csrf_enabled?).to be(false)

      expect(config.security_headers).not_to have_key('strict-transport-security')

      expect(config.security_headers).not_to have_key('content-security-policy')

      expect(config.security_headers).not_to have_key('x-frame-options')

      puts "\n=== DEBUG: Backward Compatibility Check ==="
      puts "CSRF enabled: #{config.csrf_enabled?}"
      puts "Dangerous headers present: #{(config.security_headers.keys & %w[strict-transport-security
                                                                            content-security-policy x-frame-options]).join(', ')}"
      puts "Safe headers present: #{(config.security_headers.keys & %w[x-content-type-options x-xss-protection
                                                                       referrer-policy]).join(', ')}"
      puts "=========================================\n"
    end
  end
end
