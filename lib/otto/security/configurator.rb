# frozen_string_literal: true

# lib/otto/security/configurator.rb

require_relative 'middleware/csrf_middleware'
require_relative 'middleware/validation_middleware'
require_relative 'middleware/rate_limit_middleware'

# Security configuration facade for Otto framework
class Otto
  module Security
    # Consolidates all security configuration methods into a single configurator class.
    # This provides a unified interface for configuring CSRF protection, input validation,
    # rate limiting, trusted proxies, and authentication strategies.
    class Configurator
      attr_reader :security_config, :middleware_stack
      attr_accessor :auth_config

      def initialize(security_config, middleware_stack, auth_config = nil)
        @security_config = security_config
        @middleware_stack = middleware_stack
        # Use provided auth_config or initialize a new one
        @auth_config = auth_config || { auth_strategies: {}, default_auth_strategy: 'noauth' }
      end

      # Unified security configuration method with sensible defaults
      #
      # Provides a comprehensive, one-stop configuration method for Otto's security features.
      # This method allows configuring multiple security aspects in a single call, with flexible options.
      #
      # @param csrf_protection [Boolean, Hash] Enable CSRF protection
      #   - `true`: Enable with default settings
      #   - `Hash`: Provide custom CSRF configuration
      # @param request_validation [Boolean] Enable input validation and sanitization
      # @param rate_limiting [Boolean, Hash] Enable rate limiting
      #   - `true`: Enable with default settings
      #   - `Hash`: Provide custom rate limiting rules
      # @param trusted_proxies [String, Array<String>] IP addresses or CIDR ranges to trust
      # @param security_headers [Hash] Custom security headers to merge with defaults
      # @param hsts [Boolean] Enable HTTP Strict Transport Security
      # @param csp [Boolean, String] Enable Content Security Policy
      # @param frame_protection [Boolean, String] Enable frame protection
      # @param authentication [Boolean] Enable authentication
      #
      # @example Configure multiple security features in one call
      #   otto.security.configure(
      #     csrf_protection: true,
      #     request_validation: true,
      #     rate_limiting: { requests_per_minute: 100 },
      #     trusted_proxies: ['10.0.0.0/8'],
      #     security_headers: { 'x-custom-header' => 'value' },
      #     hsts: true,
      #     csp: "default-src 'self'",
      #     frame_protection: 'SAMEORIGIN'
      #   )
      def configure(
        csrf_protection: false,
        request_validation: false,
        rate_limiting: false,
        trusted_proxies: [],
        security_headers: {},
        hsts: false,
        csp: false,
        frame_protection: false,
        authentication: false
      )
        enable_csrf_protection! if csrf_protection
        enable_request_validation! if request_validation
        enable_rate_limiting!(rate_limiting.is_a?(Hash) ? rate_limiting : {}) if rate_limiting

        Array(trusted_proxies).each { |proxy| add_trusted_proxy(proxy) }
        self.security_headers = security_headers unless security_headers.empty?

        enable_hsts! if hsts
        enable_csp! if csp
        enable_frame_protection! if frame_protection
      end

      # Enable CSRF protection for POST, PUT, DELETE, and PATCH requests.
      # This will automatically add CSRF tokens to HTML forms and validate
      # them on unsafe HTTP methods.
      def enable_csrf_protection!
        return if middleware_enabled?(Otto::Security::Middleware::CSRFMiddleware)

        @security_config.enable_csrf_protection!
        @middleware_stack.add(Otto::Security::Middleware::CSRFMiddleware)
      end

      # Enable request validation including input sanitization, size limits,
      # and protection against XSS and SQL injection attacks.
      def enable_request_validation!
        return if middleware_enabled?(Otto::Security::Middleware::ValidationMiddleware)

        @security_config.input_validation = true
        @middleware_stack.add(Otto::Security::Middleware::ValidationMiddleware)
      end

      # Enable rate limiting to protect against abuse and DDoS attacks.
      # This will automatically add rate limiting rules based on client IP.
      #
      # @param options [Hash] Rate limiting configuration options
      # @option options [Integer] :requests_per_minute Maximum requests per minute per IP (default: 100)
      # @option options [Hash] :custom_rules Custom rate limiting rules
      def enable_rate_limiting!(options = {})
        return if middleware_enabled?(Otto::Security::Middleware::RateLimitMiddleware)

        configure_rate_limiting(options)
        @middleware_stack.add(Otto::Security::Middleware::RateLimitMiddleware)
      end

      # Add a custom rate limiting rule.
      #
      # @param name [String, Symbol] Rule name
      # @param options [Hash] Rule configuration
      # @option options [Integer] :limit Maximum requests
      # @option options [Integer] :period Time period in seconds (default: 60)
      # @option options [Proc] :condition Optional condition proc that receives request
      def add_rate_limit_rule(name, options)
        @security_config.rate_limiting_config[:custom_rules] ||= {}
        @security_config.rate_limiting_config[:custom_rules][name.to_s] = options
      end

      # Add a trusted proxy server for accurate client IP detection.
      # Only requests from trusted proxies will have their forwarded headers honored.
      #
      # @param proxy [String, Regexp] IP address, CIDR range, or regex pattern
      def add_trusted_proxy(proxy)
        @security_config.add_trusted_proxy(proxy)
      end

      # Set custom security headers that will be added to all responses.
      # These merge with the default security headers.
      #
      # @param headers [Hash] Hash of header name => value pairs
      def security_headers=(headers)
        @security_config.security_headers.merge!(headers)
      end

      # Enable HTTP Strict Transport Security (HSTS) header.
      # WARNING: This can make your domain inaccessible if HTTPS is not properly
      # configured. Only enable this when you're certain HTTPS is working correctly.
      #
      # @param max_age [Integer] Maximum age in seconds (default: 1 year)
      # @param include_subdomains [Boolean] Apply to all subdomains (default: true)
      def enable_hsts!(max_age: 31_536_000, include_subdomains: true)
        @security_config.enable_hsts!(max_age: max_age, include_subdomains: include_subdomains)
      end

      # Enable Content Security Policy (CSP) header to prevent XSS attacks.
      # The default policy only allows resources from the same origin.
      #
      # @param policy [String] CSP policy string (default: "default-src 'self'")
      def enable_csp!(policy = "default-src 'self'")
        @security_config.enable_csp!(policy)
      end

      # Enable X-Frame-Options header to prevent clickjacking attacks.
      #
      # @param option [String] Frame options: 'DENY', 'SAMEORIGIN', or 'ALLOW-FROM uri'
      def enable_frame_protection!(option = 'SAMEORIGIN')
        @security_config.enable_frame_protection!(option)
      end

      # Enable Content Security Policy (CSP) with nonce support for dynamic header generation.
      # This enables the res.send_csp_headers response helper method.
      #
      # @param debug [Boolean] Enable debug logging for CSP headers (default: false)
      def enable_csp_with_nonce!(debug: false)
        @security_config.enable_csp_with_nonce!(debug: debug)
      end

      # Add a single authentication strategy
      #
      # @param name [String] Strategy name
      # @param strategy [Otto::Security::Authentication::AuthStrategy] Strategy instance
      def add_auth_strategy(name, strategy)
        @auth_config[:auth_strategies][name] = strategy
      end

      # Configure authentication strategies for route-level access control.
      #
      # @param strategies [Hash] Hash mapping strategy names to strategy instances
      # @param default_strategy [String] Default strategy to use when none specified
      def configure_auth_strategies(strategies, default_strategy: 'noauth')
        # Merge new strategies with existing ones, preserving shared state
        @auth_config[:auth_strategies].merge!(strategies)
        @auth_config[:default_auth_strategy] = default_strategy
      end

      # Configure rate limiting settings.
      #
      # @param config [Hash] Rate limiting configuration
      # @option config [Integer] :requests_per_minute Maximum requests per minute per IP
      # @option config [Hash] :custom_rules Hash of custom rate limiting rules
      # @option config [Object] :cache_store Custom cache store for rate limiting
      def configure_rate_limiting(config)
        @security_config.rate_limiting_config.merge!(config)
      end

      private

      def middleware_enabled?(middleware_class)
        @middleware_stack.includes?(middleware_class)
      end
    end
  end
end
