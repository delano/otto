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

      # Generate a cryptographically secure CSRF token
      #
      # The token consists of a random component and a signature based on the
      # session ID to prevent token reuse across sessions.
      #
      # @param session_id [String, nil] Optional session identifier for token binding
      # @return [String] CSRF token in format "token:signature"
      def generate_csrf_token(session_id = nil)
        base = session_id || SecureRandom.hex(16)
        token = SecureRandom.hex(32)
        signature = Digest::SHA256.hexdigest("#{base}:#{token}")
        "#{token}:#{signature}"
      end

      # Verify a CSRF token's authenticity and validity
      #
      # Uses constant-time comparison to prevent timing attacks.
      #
      # @param token [String, nil] CSRF token to verify
      # @param session_id [String, nil] Session identifier for token binding
      # @return [Boolean] true if token is valid and authentic
      def verify_csrf_token(token, session_id = nil)
        return false if token.nil? || token.empty?

        parts = token.split(':')
        return false if parts.length != 2

        token_part, signature = parts
        base = session_id || SecureRandom.hex(16)
        expected_signature = Digest::SHA256.hexdigest("#{base}:#{token_part}")

        # Use secure comparison to prevent timing attacks
        secure_compare(signature, expected_signature)
      end

      private

      # Default security headers applied to all responses
      #
      # These headers provide defense-in-depth against common web vulnerabilities:
      # - x-frame-options: Prevents clickjacking attacks
      # - x-content-type-options: Prevents MIME type sniffing
      # - x-xss-protection: Enables browser XSS filtering
      # - referrer-policy: Controls referrer information leakage
      # - content-security-policy: Prevents XSS and injection attacks
      # - strict-transport-security: Enforces HTTPS connections
      #
      # @return [Hash] Hash of header names and values (all lowercase for Rack 3+)
      def default_security_headers
        {
          'x-frame-options' => 'DENY',
          'x-content-type-options' => 'nosniff',
          'x-xss-protection' => '1; mode=block',
          'referrer-policy' => 'strict-origin-when-cross-origin',
          'content-security-policy' => "default-src 'self'",
          'strict-transport-security' => 'max-age=31536000; includeSubDomains'
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
