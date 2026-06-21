# lib/otto/security/config.rb
#
# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'openssl'
require 'ipaddr'
require_relative '../core/freezable'

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
      include Otto::Core::Freezable

      # Error raised when the two mutually-exclusive trusted-proxy resolution
      # modes are configured together: CIDR-walk (enumerated #trusted_proxies)
      # and count-based depth (#trusted_proxy_depth >= 1).
      PROXY_MODE_CONFLICT_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        Cannot configure both trusted_proxies (CIDR filter mode) and
        trusted_proxy_depth >= 1 (count mode). Enumerate proxy CIDRs OR set a
        hop count, not both.
      MSG

      # Error raised when CSRF protection is enabled in production without an
      # explicitly configured secret. A randomly-generated per-process secret
      # silently breaks token verification across workers and restarts, so we
      # refuse it in production rather than serve intermittently-failing tokens.
      CSRF_SECRET_REQUIRED_MESSAGE = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        CSRF protection is enabled in production without a configured secret.
        Set OTTO_CSRF_SECRET (or config.csrf_secret=) to a stable random value
        (e.g. SecureRandom.hex(32)); a per-process random secret is not valid
        across workers or restarts.
      MSG

      attr_accessor :input_validation, :max_param_depth, :csrf_token_key,
                    :rate_limiting_config, :csrf_session_key, :max_request_size,
                    :max_param_keys

      attr_reader :csrf_protection,  :csrf_header_key,
                  :trusted_proxies, :require_secure_cookies,
                  :security_headers,
                  :csp_nonce_enabled, :debug_csp, :mcp_auth,
                  :ip_privacy_config, :trusted_proxy_depth

      # Initialize security configuration with safe defaults
      #
      # All security features are disabled by default to maintain backward
      # compatibility with existing Otto applications.
      def initialize
        @csrf_protection        = false
        @csrf_token_key         = '_csrf_token'
        @csrf_header_key        = 'HTTP_X_CSRF_TOKEN'
        @csrf_session_key       = '_csrf_session_id'
        @max_request_size       = 10 * 1024 * 1024 # 10MB
        @max_param_depth        = 32
        @max_param_keys         = 64
        @trusted_proxies        = []
        @trusted_proxy_matchers = []
        @trusted_proxy_depth    = nil
        @require_secure_cookies = false
        @security_headers       = default_security_headers
        @input_validation       = true
        @csp_nonce_enabled      = false
        @debug_csp              = false
        @rate_limiting_config   = { custom_rules: {} }
        @ip_privacy_config      = Otto::Privacy::Config.new

        configured_secret      = ENV.fetch('OTTO_CSRF_SECRET', nil)
        @csrf_secret_generated = configured_secret.nil? || configured_secret.empty?
        @csrf_secret           = @csrf_secret_generated ? SecureRandom.hex(32) : configured_secret
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
      # @raise [FrozenError] if configuration is frozen
      def enable_csrf_protection!
        ensure_not_frozen!

        @csrf_protection = true
      end

      # Disable CSRF protection
      #
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def disable_csrf_protection!
        ensure_not_frozen!

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
      # @raise [FrozenError] if configuration is frozen
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
        ensure_not_frozen!
        # CIDR-walk and count-based depth are mutually exclusive. Catch the
        # conflict eagerly here (and in #trusted_proxy_depth=) so it surfaces at
        # configuration time, not only at freeze (which the test harness skips).
        raise ArgumentError, PROXY_MODE_CONFLICT_MESSAGE if trusted_proxy_depth_mode?

        case proxy
        when String, Regexp
          @trusted_proxies << proxy
          @trusted_proxy_matchers << register_proxy_matcher(proxy)
        when Array
          proxy.each { |entry| @trusted_proxy_matchers << register_proxy_matcher(entry) }
          @trusted_proxies.concat(proxy)
        else
          raise ArgumentError, 'Proxy must be a String, Regexp, or Array'
        end
      end

      # Check if an IP address is from a trusted proxy
      #
      # String entries that parse as an IP or CIDR range are matched with
      # proper IPAddr containment (IPv4 and IPv6). Entries that are not valid
      # IPs (e.g. a bare prefix like '172.16.') fall back to the legacy
      # exact/prefix string match for backward compatibility. Regexp entries
      # are matched against the raw IP string.
      #
      # Proxy entries are parsed once at registration (see #add_trusted_proxy)
      # into @trusted_proxy_matchers, so this never re-parses per request.
      #
      # @param ip [String] IP address to check
      # @return [Boolean] true if the IP is from a trusted proxy
      def trusted_proxy?(ip)
        return false if @trusted_proxy_matchers.empty? || ip.nil? || ip.empty?

        # Fold IPv4-mapped IPv6 (::ffff:a.b.c.d) to plain IPv4 so a dual-stack
        # peer presented in mapped form still matches an IPv4 proxy entry.
        client = parse_ipaddr(ip)&.native

        @trusted_proxy_matchers.any? do |entry, range|
          if range
            # Pre-parsed IP/CIDR entry -> proper containment
            client && ip_in_range?(range, client)
          elsif entry.is_a?(Regexp)
            entry.match?(ip)
          elsif entry.is_a?(String)
            # Legacy non-IP entry (e.g. '172.16.') -> exact/prefix match
            ip == entry || ip.start_with?(entry)
          else
            false
          end
        end
      end

      # Whether count-based ("trust the last N hops") proxy resolution is active.
      #
      # When true, Otto::Utils.resolve_client_ip ignores trusted-proxy CIDRs and
      # instead trusts a fixed number of hops from the right of the forwarded
      # chain (Express `trust proxy = N`). This is the only sound model for
      # non-enumerable proxy tiers (Fly, cloud load balancers, dynamic reverse
      # proxies) whose addresses cannot be listed as CIDRs.
      #
      # @return [Boolean] true when trusted_proxy_depth is an Integer >= 1
      def trusted_proxy_depth_mode?
        @trusted_proxy_depth.is_a?(Integer) && @trusted_proxy_depth >= 1
      end

      # Set the count-based trusted-proxy depth ("trust the last N hops").
      #
      # Validates eagerly so a misconfiguration fails at assignment rather than
      # only at freeze (which the test harness skips): the value must be a
      # non-negative Integer or nil, and the mode is mutually exclusive with
      # CIDR-walk (trusted_proxies). nil/0 disable depth mode.
      #
      # @param depth [Integer, nil] number of trusted hops (nil/0 disables depth mode)
      # @raise [FrozenError] if configuration is frozen
      # @raise [ArgumentError] if depth is non-integer/negative, or if
      #   trusted_proxies are already configured and depth >= 1
      def trusted_proxy_depth=(depth)
        ensure_not_frozen!

        validate_trusted_proxy_depth!(depth)
        raise ArgumentError, PROXY_MODE_CONFLICT_MESSAGE if depth.to_i >= 1 && @trusted_proxies.any?

        @trusted_proxy_depth = depth
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

      # Set the server-side secret used to sign (HMAC) CSRF tokens. Set this to
      # a stable value (e.g. ENV['OTTO_CSRF_SECRET']) in multi-process or
      # multi-host deployments so tokens stay valid across workers and restarts.
      #
      # Write-only by design: the signing key has no public reader, so it is not
      # exposed to inspection/logging/serialization via the config object.
      def csrf_secret=(secret)
        ensure_not_frozen!

        @csrf_secret           = secret
        @csrf_secret_generated = false
      end

      # Generate a CSRF token bound to the given session id and signed (HMAC-SHA256)
      # with the server-side secret, so tokens cannot be self-minted and are not
      # valid across sessions. A session binding is REQUIRED.
      def generate_csrf_token(session_id = nil)
        binding_id = session_id.to_s
        raise ArgumentError, 'CSRF token generation requires a session binding' if binding_id.empty?

        reject_generated_secret_in_production!
        warn_generated_csrf_secret
        token = SecureRandom.hex(32)
        "#{token}:#{sign_csrf_token(binding_id, token)}"
      end

      # Verify a CSRF token against its session binding using a constant-time
      # comparison. Returns false (never raises) for blank/malformed input.
      def verify_csrf_token(token, session_id = nil)
        return false if token.nil? || token.empty?

        binding_id = session_id.to_s
        return false if binding_id.empty?

        token_part, signature = token.split(':', 2)
        return false if token_part.nil? || signature.nil?

        expected_signature = sign_csrf_token(binding_id, token_part)
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
      # @raise [FrozenError] if configuration is frozen
      def enable_hsts!(max_age: 31_536_000, include_subdomains: true)
        ensure_not_frozen!

        hsts_value                                     = "max-age=#{max_age}"
        hsts_value                                    += '; includeSubDomains' if include_subdomains
        @security_headers['strict-transport-security'] = hsts_value
      end

      # Enable Content Security Policy (CSP) header
      #
      # CSP helps prevent XSS attacks by controlling which resources can be loaded.
      # The default policy only allows resources from the same origin.
      #
      # @param policy [String] CSP policy string (default: "default-src 'self'")
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      #
      # @example Custom policy
      #   config.enable_csp!("default-src 'self'; script-src 'self' 'unsafe-inline'")
      def enable_csp!(policy = "default-src 'self'")
        ensure_not_frozen!

        @security_headers['content-security-policy'] = policy
      end

      # Enable Content Security Policy (CSP) with nonce support
      #
      # This enables dynamic CSP header generation with nonces for enhanced security.
      # Unlike enable_csp!, this doesn't set a static policy but enables the response
      # helper to generate CSP headers with nonces on a per-request basis.
      #
      # @param debug [Boolean] Enable debug logging for CSP headers (default: false)
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      #
      # @example
      #   config.enable_csp_with_nonce!(debug: true)
      def enable_csp_with_nonce!(debug: false)
        ensure_not_frozen!

        @csp_nonce_enabled = true
        @debug_csp         = debug
      end

      # Disable CSP nonce support
      #
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def disable_csp_nonce!
        ensure_not_frozen!

        @csp_nonce_enabled = false
      end

      # Check if CSP nonce support is enabled
      #
      # @return [Boolean] true if CSP nonce support is enabled
      def csp_nonce_enabled?
        @csp_nonce_enabled
      end

      # Check if CSP debug logging is enabled
      #
      # @return [Boolean] true if CSP debug logging is enabled
      def debug_csp?
        @debug_csp
      end

      # Generate a CSP policy string with the provided nonce
      #
      # @param nonce [String] The nonce value to include in the CSP
      # @param development_mode [Boolean] Whether to use development-friendly directives
      # @return [String] Complete CSP policy string
      def generate_nonce_csp(nonce, development_mode: false)
        directives = development_mode ? development_csp_directives(nonce) : production_csp_directives(nonce)
        directives.join(' ')
      end

      # Enable X-Frame-Options header to prevent clickjacking
      #
      # @param option [String] Frame options: 'DENY', 'SAMEORIGIN', or 'ALLOW-FROM uri'
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      def enable_frame_protection!(option = 'SAMEORIGIN')
        ensure_not_frozen!

        @security_headers['x-frame-options'] = option
      end

      # Set custom security headers
      #
      # @param headers [Hash] Hash of header name => value pairs
      # @return [void]
      # @raise [FrozenError] if configuration is frozen
      #
      # @example
      #   config.set_custom_headers({
      #     'permissions-policy' => 'geolocation=(), microphone=()',
      #     'cross-origin-opener-policy' => 'same-origin'
      #   })
      def set_custom_headers(headers)
        ensure_not_frozen!

        @security_headers.merge!(headers)
      end

      # Override deep_freeze! to ensure rate_limiting_config has custom_rules initialized
      #
      # This pre-initializes any lazy values before freezing to prevent FrozenError
      # when accessing configuration after it's frozen.
      #
      # @return [self] The frozen configuration
      def deep_freeze!
        # Ensure custom_rules is initialized (should already be done in constructor)
        @rate_limiting_config[:custom_rules] ||= {}
        validate_trusted_proxy_config!
        validate_csrf_secret_config!
        super
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

      # Guard for mutators: refuse changes once the configuration is frozen.
      # Centralizes the repeated frozen-check so every setter shares one message.
      def ensure_not_frozen!
        raise FrozenError, 'Cannot modify frozen configuration' if frozen?
      end

      # Validate a candidate trusted_proxy_depth value (type and range).
      #
      # Shared by the eager #trusted_proxy_depth= setter and the freeze-time
      # backstop so an invalid value raises a clear ArgumentError instead of a
      # downstream NoMethodError from #to_i coercion. nil disables depth mode.
      #
      # @param depth [Object] candidate value
      # @raise [ArgumentError] if depth is non-nil and not a non-negative Integer
      # @return [void]
      def validate_trusted_proxy_depth!(depth)
        return if depth.nil?

        unless depth.is_a?(Integer)
          raise ArgumentError,
                "trusted_proxy_depth must be an Integer or nil, got #{depth.class}"
        end

        raise ArgumentError, "trusted_proxy_depth must be >= 0, got #{depth}" if depth.negative?
      end

      # Validate trusted-proxy configuration coherence at freeze time.
      #
      # The eager setters (#trusted_proxy_depth=, #add_trusted_proxy) already
      # reject invalid types and the mutually-exclusive CIDR-walk vs depth
      # combination at assignment. This re-checks at finalization as a backstop
      # for a direct/ivar configuration path that bypassed the setters.
      #
      # @raise [ArgumentError] if depth is non-integer/negative, or if both
      #   trusted_proxies and a depth >= 1 are configured
      # @return [void]
      def validate_trusted_proxy_config!
        validate_trusted_proxy_depth!(@trusted_proxy_depth)
        return if @trusted_proxy_depth.nil?

        raise ArgumentError, PROXY_MODE_CONFLICT_MESSAGE if @trusted_proxy_depth >= 1 && @trusted_proxies.any?
      end

      # Parse a value into an IPAddr, returning nil for invalid / non-IP input.
      #
      # @param value [String] candidate IP or CIDR string
      # @return [IPAddr, nil]
      def parse_ipaddr(value)
        IPAddr.new(value)
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        nil
      end

      # Build a cached matcher tuple for a proxy entry at registration time.
      #
      # String entries are parsed to an IPAddr exactly once here; the result is
      # reused for both the legacy-entry warning and per-request matching, so
      # trusted_proxy? never re-parses. Non-IP strings and Regexp/other entries
      # store a nil range and fall back to prefix/regexp matching.
      #
      # @param entry [String, Regexp, Object] trusted proxy entry being added
      # @return [Array(Object, IPAddr)] [raw_entry, parsed_range_or_nil]
      def register_proxy_matcher(entry)
        return [entry, nil] unless entry.is_a?(String)

        range = parse_ipaddr(entry)
        warn_legacy_proxy_entry(entry) unless range
        [entry, range]
      end

      # Warn that a string proxy entry is not a valid IP/CIDR and will use
      # legacy string-prefix matching.
      #
      # @param entry [String] trusted proxy entry
      # @return [void]
      def warn_legacy_proxy_entry(entry)
        Otto.logger.warn(
          "[Otto::Security::Config] trusted proxy #{entry.inspect} is not a " \
          'valid IP or CIDR; using legacy string-prefix matching. Prefer a ' \
          "CIDR range (e.g. '172.16.0.0/12')."
        )
      end

      # CIDR/host containment that is safe across address families.
      #
      # @param range [IPAddr] trusted proxy range or host
      # @param client [IPAddr] client address
      # @return [Boolean]
      def ip_in_range?(range, client)
        return false unless range.family == client.family

        range.include?(client)
      rescue IPAddr::InvalidAddressError
        false
      end

      def extract_existing_session_id(request)
        # Try session first
        begin
          session = request.session
          if session
            return session.id if session.respond_to?(:id) && session.id
            return session[csrf_session_key] if session[csrf_session_key]
            return session['session_id'] if session['session_id']
          end
        rescue StandardError
          # Fall through to cookies
        end

        # Try cookies
        request.cookies['_otto_session'] ||
          request.cookies['session_id'] ||
          request.cookies['_session_id']
      end

      def store_session_id(request, session_id)
        session                   = request.session
        session[csrf_session_key] = session_id if session
      rescue StandardError
        # Cookie fallback handled in inject_csrf_token
      end

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
          'referrer-policy' => 'strict-origin-when-cross-origin',
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

        result                                = 0
        a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
        result == 0
      end

      # HMAC-SHA256 signature binding a token's random component to a session id
      # and the server-side secret. Keyed HMAC (not a bare digest) is what prevents
      # token self-minting.
      def sign_csrf_token(session_id, token)
        OpenSSL::HMAC.hexdigest('SHA256', @csrf_secret, "#{session_id}:#{token}")
      end

      # Warn once per config instance when CSRF tokens are being signed with a
      # randomly-generated per-process secret. Such tokens do not survive process
      # restarts and are not shared across workers; set OTTO_CSRF_SECRET (or
      # config.csrf_secret=) for stable multi-process behavior.
      def warn_generated_csrf_secret
        return unless @csrf_secret_generated
        return if @csrf_secret_warning_emitted

        @csrf_secret_warning_emitted = true
        Otto.logger.warn(<<~MSG.gsub(/\s+/, ' ').strip)
          [Otto::Security::Config] CSRF tokens are signed with a randomly
          generated per-process secret; they will not survive restarts or be
          valid across workers. Set OTTO_CSRF_SECRET (or config.csrf_secret=)
          for stable CSRF tokens in multi-process deployments.
        MSG
      end

      # Freeze-time backstop: refuse to finalize a production configuration that
      # enables CSRF with a generated (non-configured) secret. Mirrors
      # #validate_trusted_proxy_config! so the failure surfaces at boot, before
      # serving traffic, for apps that deep-freeze their config.
      def validate_csrf_secret_config!
        raise ArgumentError, CSRF_SECRET_REQUIRED_MESSAGE if csrf_secret_unsafe_for_production?
      end

      # Generation-time guard for apps that never freeze their config: never
      # mint a CSRF token signed with a generated per-process secret in
      # production (fail loud instead of serving tokens that won't verify).
      def reject_generated_secret_in_production!
        raise ArgumentError, CSRF_SECRET_REQUIRED_MESSAGE if csrf_secret_unsafe_for_production?
      end

      # True when CSRF is enabled, the secret was randomly generated (not
      # configured via OTTO_CSRF_SECRET / #csrf_secret=), and we are running in
      # a production environment.
      def csrf_secret_unsafe_for_production?
        @csrf_protection && @csrf_secret_generated && production_environment?
      end

      # Whether RACK_ENV indicates a production deployment. Gated to an explicit
      # allowlist (not "anything but dev") so test/unknown environments keep the
      # zero-config generated-secret fallback.
      def production_environment?
        defined?(Otto) && Otto.respond_to?(:env?) && Otto.env?(:production, :prod)
      end

      # Generate CSP directives for development environment
      #
      # Development mode allows inline scripts/styles and hot reloading connections
      # for better developer experience with build tools like Vite.
      #
      # @param nonce [String] The nonce value to include in script-src
      # @return [Array<String>] Array of CSP directive strings
      def development_csp_directives(nonce)
        [
          "default-src 'none';",
          "script-src 'nonce-#{nonce}' 'unsafe-inline';", # Allow inline scripts for development tools
          "style-src 'self' 'unsafe-inline';",
          "connect-src 'self' ws: wss: http: https:;", # Allow HTTP and all WebSocket connections for dev tools
          "img-src 'self' data:;",
          "font-src 'self';",
          "object-src 'none';",
          "base-uri 'self';",
          "form-action 'self';",
          "frame-ancestors 'none';",
          "manifest-src 'self';",
          "worker-src 'self' data:;",
        ]
      end

      # Generate CSP directives for production environment
      #
      # Production mode is more restrictive, only allowing HTTPS connections
      # and nonce-only scripts for enhanced XSS protection.
      #
      # @param nonce [String] The nonce value to include in script-src
      # @return [Array<String>] Array of CSP directive strings
      def production_csp_directives(nonce)
        [
          "default-src 'none';",                     # Restrict to same origin by default
          "script-src 'nonce-#{nonce}';",            # Only allow scripts with valid nonce
          "style-src 'self' 'unsafe-inline';",       # Allow inline styles and same-origin stylesheets
          "connect-src 'self' wss: https:;",         # Only HTTPS and secure WebSockets
          "img-src 'self' data:;",                   # Allow images from same origin and data URIs
          "font-src 'self';",                        # Allow fonts from same origin only
          "object-src 'none';",                      # Block <object>, <embed>, and <applet> elements
          "base-uri 'self';",                        # Restrict <base> tag targets to same origin
          "form-action 'self';",                     # Restrict form submissions to same origin
          "frame-ancestors 'none';",                 # Prevent site from being embedded in frames
          "manifest-src 'self';",                    # Allow web app manifests from same origin
          "worker-src 'self' data:;",                # Allow Workers from same origin and data blobs
        ]
      end
    end

    # Raised when a request exceeds the configured size limit
    class RequestTooLargeError < Otto::PayloadTooLargeError; end

    # Raised when CSRF token validation fails
    class CSRFError < Otto::ForbiddenError; end

    # Raised when input validation fails (XSS, SQL injection, etc.)
    class ValidationError < Otto::BadRequestError; end
  end
end
