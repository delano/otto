# lib/otto/security/config.rb

require 'securerandom'
require 'digest'

class Otto
  module Security
    # Security configuration for Otto applications
    #
    # This class manages all security-related settings including CSRF protection,
    # input validation, trusted proxies, and security headers. Security features
    # are disabled by default for backward compatibility.
    #
    # @example Basic usage
    #   config = Otto::Security::Config.new
    #   config.enable_csrf_protection!
    #   config.add_trusted_proxy('10.0.0.0/8')
    #
    # @example Custom limits
    #   config = Otto::Security::Config.new
    #   config.max_request_size = 5 * 1024 * 1024  # 5MB
    #   config.max_param_depth = 16
    class Config
      attr_accessor :csrf_protection, :csrf_token_key, :csrf_header_key,
                    :max_request_size, :max_param_depth, :max_param_keys,
                    :trusted_proxies, :require_secure_cookies,
                    :security_headers, :input_validation

      # Initialize security configuration with safe defaults
      #
      # All security features are disabled by default to maintain backward
      # compatibility with existing Otto applications.
      def initialize
        @csrf_protection = false
        @csrf_token_key = '_csrf_token'
        @csrf_header_key = 'HTTP_X_CSRF_TOKEN'
        @max_request_size = 10 * 1024 * 1024 # 10MB
        @max_param_depth = 32
        @max_param_keys = 64
        @trusted_proxies = []
        @require_secure_cookies = false
        @security_headers = default_security_headers
        @input_validation = true
      end

      # Enable CSRF (Cross-Site Request Forgery) protection
      #
      # When enabled, Otto will:
      # - Generate CSRF tokens for safe HTTP methods (GET, HEAD, OPTIONS, TRACE)
      # - Validate CSRF tokens for unsafe methods (POST, PUT, DELETE, PATCH)
      # - Automatically inject CSRF meta tags into HTML responses
      # - Provide helper methods for forms and AJAX requests
      #
      # @return [void]
      def enable_csrf_protection!
        @csrf_protection = true
      end

      # Disable CSRF protection
      #
      # @return [void]
      def disable_csrf_protection!
        @csrf_protection = false
      end

      # Check if CSRF protection is currently enabled
      #
      # @return [Boolean] true if CSRF protection is enabled
      def csrf_enabled?
        @csrf_protection
      end

      # Add a trusted proxy server for accurate client IP detection
      #
      # Only requests from trusted proxies will have their X-Forwarded-For
      # and similar headers honored for IP detection. This prevents IP spoofing
      # from untrusted sources.
      #
      # @param proxy [String, Array] IP address, CIDR range, or array of addresses
      # @raise [ArgumentError] if proxy is not a String or Array
      # @return [void]
      #
      # @example Add single proxy
      #   config.add_trusted_proxy('10.0.0.1')
      #
      # @example Add CIDR range
      #   config.add_trusted_proxy('192.168.0.0/16')
      #
      # @example Add multiple proxies
      #   config.add_trusted_proxy(['10.0.0.1', '172.16.0.0/12'])
      def add_trusted_proxy(proxy)
        case proxy
        when String
          @trusted_proxies << proxy
        when Array
          @trusted_proxies.concat(proxy)
        else
          raise ArgumentError, "Proxy must be a String or Array"
        end
      end

      # Check if an IP address is from a trusted proxy
      #
      # @param ip [String] IP address to check
      # @return [Boolean] true if the IP is from a trusted proxy
      def trusted_proxy?(ip)
        return false if @trusted_proxies.empty?

        @trusted_proxies.any? do |proxy|
          case proxy
          when String
            ip == proxy || ip.start_with?(proxy)
          when Regexp
            proxy.match?(ip)
          else
            false
          end
        end
      end

      # Validate that a request size is within acceptable limits
      #
      # @param content_length [String, Integer, nil] Content-Length header value
      # @raise [Otto::Security::RequestTooLargeError] if request exceeds maximum size
      # @return [Boolean] true if request size is acceptable
      def validate_request_size(content_length)
        return true if content_length.nil?

        size = content_length.to_i
        if size > @max_request_size
          raise Otto::Security::RequestTooLargeError,
                "Request size #{size} exceeds maximum #{@max_request_size}"
        end
        true
      end

      def generate_csrf_token(session_id = nil)
        base = session_id || 'no-session'
        token = SecureRandom.hex(32)
        signature = Digest::SHA256.hexdigest("#{base}:#{token}")

        puts "=== CSRF Generation ==="
        puts "session_id: #{session_id.inspect}"
        puts "base: #{base.inspect}"
        puts "token: #{token.inspect}"
        puts "hash_input: #{(base + ':' + token).inspect}"
        puts "signature: #{signature}"
        puts "final_token: #{(token + ':' + signature).inspect}"

        "#{token}:#{signature}"
      end

      def verify_csrf_token(token, session_id = nil)
        return false if token.nil? || token.empty?

        token_part, signature = token.split(':')
        return false if token_part.nil? || signature.nil?

        base = session_id || 'no-session'
        expected_signature = Digest::SHA256.hexdigest("#{base}:#{token_part}")

        puts "=== CSRF Verification ==="
        puts "session_id: #{session_id.inspect}"
        puts "base: #{base.inspect}"
        puts "token_part: #{token_part.inspect}"
        puts "hash_input: #{(base + ':' + token_part).inspect}"
        puts "received_signature: #{signature}"
        puts "expected_signature: #{expected_signature}"
        puts "match: #{secure_compare(signature, expected_signature)}"

        secure_compare(signature, expected_signature)
      end

      # Enable HTTP Strict Transport Security (HSTS) header
      #
      # HSTS forces browsers to use HTTPS for all future requests to this domain.
      # WARNING: This can make your domain inaccessible if HTTPS is not properly
      # configured. Only enable this when you're certain HTTPS is working correctly.
      #
      # @param max_age [Integer] Maximum age in seconds (default: 1 year)
      # @param include_subdomains [Boolean] Apply to all subdomains (default: true)
      # @return [void]
      def enable_hsts!(max_age: 31536000, include_subdomains: true)
        hsts_value = "max-age=#{max_age}"
        hsts_value += "; includeSubDomains" if include_subdomains
        @security_headers['strict-transport-security'] = hsts_value
      end

      # Enable Content Security Policy (CSP) header
      #
      # CSP helps prevent XSS attacks by controlling which resources can be loaded.
      # The default policy only allows resources from the same origin.
      #
      # @param policy [String] CSP policy string (default: "default-src 'self'")
      # @return [void]
      #
      # @example Custom policy
      #   config.enable_csp!("default-src 'self'; script-src 'self' 'unsafe-inline'")
      def enable_csp!(policy = "default-src 'self'")
        @security_headers['content-security-policy'] = policy
      end

      # Enable X-Frame-Options header to prevent clickjacking
      #
      # @param option [String] Frame options: 'DENY', 'SAMEORIGIN', or 'ALLOW-FROM uri'
      # @return [void]
      def enable_frame_protection!(option = 'SAMEORIGIN')
        @security_headers['x-frame-options'] = option
      end

      # Set custom security headers
      #
      # @param headers [Hash] Hash of header name => value pairs
      # @return [void]
      #
      # @example
      #   config.set_custom_headers({
      #     'permissions-policy' => 'geolocation=(), microphone=()',
      #     'cross-origin-opener-policy' => 'same-origin'
      #   })
      def set_custom_headers(headers)
        @security_headers.merge!(headers)
      end

      def get_or_create_session_id(request)
        # Try existing sources first
        session_id = extract_existing_session_id(request)

        # Create and persist if none found
        if session_id.nil? || session_id.empty?
          session_id = SecureRandom.hex(16)
          store_session_id(request, session_id)
        end

        session_id
      end

      private

      def extract_existing_session_id(request)
        # Try session first
        begin
          session = request.session
          if session
            return session.id if session.respond_to?(:id) && session.id
            return session['_csrf_session_id'] if session['_csrf_session_id']
          end
        rescue
          # Fall through to cookies
        end

        # Try cookies
        request.cookies['_otto_session'] ||
        request.cookies['session_id'] ||
        request.cookies['_session_id']
      end

      def store_session_id(request, session_id)
        begin
          session = request.session
          session['_csrf_session_id'] = session_id if session
        rescue
          # Cookie fallback handled in inject_csrf_token
        end
      end

      private

      # Default security headers applied to all responses
      #
      # These headers provide basic defense against common web vulnerabilities:
      # - x-content-type-options: Prevents MIME type sniffing
      # - x-xss-protection: Enables browser XSS filtering (legacy browsers)
      # - referrer-policy: Controls referrer information leakage
      #
      # Note: Restrictive headers like HSTS, CSP, and X-Frame-Options are not
      # included by default to avoid breaking downstream applications. These
      # should be configured explicitly when appropriate.
      #
      # @return [Hash] Hash of header names and values (all lowercase for Rack 3+)
      def default_security_headers
        {
          'x-content-type-options' => 'nosniff',
          'x-xss-protection' => '1; mode=block',
          'referrer-policy' => 'strict-origin-when-cross-origin'
        }
      end

      # Perform constant-time string comparison to prevent timing attacks
      #
      # This method compares two strings in constant time regardless of where
      # they differ, preventing attackers from using timing differences to
      # deduce information about secret values.
      #
      # @param a [String, nil] First string to compare
      # @param b [String, nil] Second string to compare
      # @return [Boolean] true if strings are equal
      def secure_compare(a, b)
        return false if a.nil? || b.nil? || a.length != b.length

        result = 0
        a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
        result == 0
      end
    end

    # Raised when a request exceeds the configured size limit
    class RequestTooLargeError < StandardError; end

    # Raised when CSRF token validation fails
    class CSRFError < StandardError; end

    # Raised when input validation fails (XSS, SQL injection, etc.)
    class ValidationError < StandardError; end
  end
end
