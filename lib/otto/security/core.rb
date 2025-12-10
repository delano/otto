# lib/otto/security/core.rb
#
# frozen_string_literal: true

class Otto
  module Security
    # Core security configuration methods included in the Otto class.
    # Provides the public API for enabling and configuring security features.
    module Core
      # Enable CSRF protection for POST, PUT, DELETE, and PATCH requests.
      # This will automatically add CSRF tokens to HTML forms and validate
      # them on unsafe HTTP methods.
      #
      # @example
      #   otto.enable_csrf_protection!
      def enable_csrf_protection!
        ensure_not_frozen!
        return if @middleware.includes?(Otto::Security::Middleware::CSRFMiddleware)

        @security_config.enable_csrf_protection!
        use Otto::Security::Middleware::CSRFMiddleware
      end

      # Enable request validation including input sanitization, size limits,
      # and protection against XSS and SQL injection attacks.
      #
      # @example
      #   otto.enable_request_validation!
      def enable_request_validation!
        ensure_not_frozen!
        return if @middleware.includes?(Otto::Security::Middleware::ValidationMiddleware)

        @security_config.input_validation = true
        use Otto::Security::Middleware::ValidationMiddleware
      end

      # Enable rate limiting to protect against abuse and DDoS attacks.
      # This will automatically add rate limiting rules based on client IP.
      #
      # @param options [Hash] Rate limiting configuration options
      # @option options [Integer] :requests_per_minute Maximum requests per minute per IP (default: 100)
      # @option options [Hash] :custom_rules Custom rate limiting rules
      # @example
      #   otto.enable_rate_limiting!(requests_per_minute: 50)
      def enable_rate_limiting!(options = {})
        ensure_not_frozen!
        return if @middleware.includes?(Otto::Security::Middleware::RateLimitMiddleware)

        @security.configure_rate_limiting(options)
        use Otto::Security::Middleware::RateLimitMiddleware
      end

      # Add a custom rate limiting rule.
      #
      # @param name [String, Symbol] Rule name
      # @param options [Hash] Rule configuration
      # @option options [Integer] :limit Maximum requests
      # @option options [Integer] :period Time period in seconds (default: 60)
      # @option options [Proc] :condition Optional condition proc that receives request
      # @example
      #   otto.add_rate_limit_rule('uploads', limit: 5, period: 300, condition: ->(req) { req.post? && req.path.include?('upload') })
      def add_rate_limit_rule(name, options)
        ensure_not_frozen!
        @security_config.rate_limiting_config[:custom_rules][name.to_s] = options
      end

      # Add a trusted proxy server for accurate client IP detection.
      # Only requests from trusted proxies will have their forwarded headers honored.
      #
      # @param proxy [String, Regexp] IP address, CIDR range, or regex pattern
      # @example
      #   otto.add_trusted_proxy('10.0.0.0/8')
      #   otto.add_trusted_proxy(/^172\.16\./)
      def add_trusted_proxy(proxy)
        ensure_not_frozen!
        @security_config.add_trusted_proxy(proxy)
      end

      # Set custom security headers that will be added to all responses.
      # These merge with the default security headers.
      #
      # @param headers [Hash] Hash of header name => value pairs
      # @example
      #   otto.set_security_headers({
      #     'content-security-policy' => "default-src 'self'",
      #     'strict-transport-security' => 'max-age=31536000'
      #   })
      def set_security_headers(headers)
        ensure_not_frozen!
        @security_config.security_headers.merge!(headers)
      end

      # Enable HTTP Strict Transport Security (HSTS) header.
      # WARNING: This can make your domain inaccessible if HTTPS is not properly
      # configured. Only enable this when you're certain HTTPS is working correctly.
      #
      # @param max_age [Integer] Maximum age in seconds (default: 1 year)
      # @param include_subdomains [Boolean] Apply to all subdomains (default: true)
      # @example
      #   otto.enable_hsts!(max_age: 86400, include_subdomains: false)
      def enable_hsts!(max_age: 31_536_000, include_subdomains: true)
        ensure_not_frozen!
        @security_config.enable_hsts!(max_age: max_age, include_subdomains: include_subdomains)
      end

      # Enable Content Security Policy (CSP) header to prevent XSS attacks.
      # The default policy only allows resources from the same origin.
      #
      # @param policy [String] CSP policy string (default: "default-src 'self'")
      # @example
      #   otto.enable_csp!("default-src 'self'; script-src 'self' 'unsafe-inline'")
      def enable_csp!(policy = "default-src 'self'")
        ensure_not_frozen!
        @security_config.enable_csp!(policy)
      end

      # Enable X-Frame-Options header to prevent clickjacking attacks.
      #
      # @param option [String] Frame options: 'DENY', 'SAMEORIGIN', or 'ALLOW-FROM uri'
      # @example
      #   otto.enable_frame_protection!('DENY')
      def enable_frame_protection!(option = 'SAMEORIGIN')
        ensure_not_frozen!
        @security_config.enable_frame_protection!(option)
      end

      # Enable Content Security Policy (CSP) with nonce support for dynamic header generation.
      # This enables the res.send_csp_headers response helper method.
      #
      # @param debug [Boolean] Enable debug logging for CSP headers (default: false)
      # @example
      #   otto.enable_csp_with_nonce!(debug: true)
      def enable_csp_with_nonce!(debug: false)
        ensure_not_frozen!
        @security_config.enable_csp_with_nonce!(debug: debug)
      end

      # Add an authentication strategy with a registered name
      #
      # This is the primary public API for registering authentication strategies.
      # The name you provide here will be available as `strategy_result.strategy_name`
      # in your application code, making it easy to identify which strategy authenticated
      # the current request.
      #
      # Also available via Otto::Security::Configurator for consolidated security config.
      #
      # @param name [String, Symbol] Strategy name (e.g., 'session', 'api_key', 'jwt')
      # @param strategy [AuthStrategy] Strategy instance
      # @example
      #   otto.add_auth_strategy('session', SessionStrategy.new(session_key: 'user_id'))
      #   otto.add_auth_strategy('api_key', APIKeyStrategy.new)
      # @raise [ArgumentError] if strategy name already registered
      def add_auth_strategy(name, strategy)
        ensure_not_frozen!
        # Ensure auth_config is initialized (handles edge case where it might be nil)
        @auth_config = { auth_strategies: {}, default_auth_strategy: 'noauth' } if @auth_config.nil?

        # Strict mode: Detect strategy name collisions
        if @auth_config[:auth_strategies].key?(name)
          raise ArgumentError, "Authentication strategy '#{name}' is already registered"
        end

        @auth_config[:auth_strategies][name] = strategy
      end
    end
  end
end
