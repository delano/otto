# frozen_string_literal: true

# lib/otto/core/configuration.rb

require_relative '../security/csrf'
require_relative '../security/validator'
require_relative '../security/authentication'
require_relative '../security/rate_limiting'
require_relative '../mcp/server'

class Otto
  module Core
    # Configuration module providing locale and application configuration methods
    module Configuration
      def configure_locale(opts)
        # Start with global configuration
        global_config = self.class.global_config
        @locale_config = nil

        # Check if we have any locale configuration from any source
        has_global_locale = global_config && (global_config[:available_locales] || global_config[:default_locale])
        has_direct_options = opts[:available_locales] || opts[:default_locale]
        has_legacy_config = opts[:locale_config]

        # Only create locale_config if we have configuration from somewhere
        return unless has_global_locale || has_direct_options || has_legacy_config

        @locale_config = {}

        # Apply global configuration first
        if global_config && global_config[:available_locales]
          @locale_config[:available_locales] =
            global_config[:available_locales]
        end
        if global_config && global_config[:default_locale]
          @locale_config[:default_locale] =
            global_config[:default_locale]
        end

        # Apply direct instance options (these override global config)
        @locale_config[:available_locales] = opts[:available_locales] if opts[:available_locales]
        @locale_config[:default_locale] = opts[:default_locale] if opts[:default_locale]

        # Legacy support: Configure locale if provided in initialization options via locale_config hash
        return unless opts[:locale_config]

        locale_opts = opts[:locale_config]
        if locale_opts[:available_locales] || locale_opts[:available]
          @locale_config[:available_locales] =
            locale_opts[:available_locales] || locale_opts[:available]
        end
        return unless locale_opts[:default_locale] || locale_opts[:default]

        @locale_config[:default_locale] =
          locale_opts[:default_locale] || locale_opts[:default]
      end

      def configure_security(opts)
        # Enable CSRF protection if requested
        enable_csrf_protection! if opts[:csrf_protection]

        # Enable request validation if requested
        enable_request_validation! if opts[:request_validation]

        # Enable rate limiting if requested
        if opts[:rate_limiting]
          rate_limiting_opts = opts[:rate_limiting].is_a?(Hash) ? opts[:rate_limiting] : {}
          enable_rate_limiting!(rate_limiting_opts)
        end

        # Add trusted proxies if provided
        Array(opts[:trusted_proxies]).each { |proxy| add_trusted_proxy(proxy) } if opts[:trusted_proxies]

        # Set custom security headers
        return unless opts[:security_headers]

        set_security_headers(opts[:security_headers])
      end

      def configure_authentication(opts)
        # Update existing @auth_config rather than creating a new one
        # to maintain synchronization with the configurator
        @auth_config[:auth_strategies] = opts[:auth_strategies] if opts[:auth_strategies]
        @auth_config[:default_auth_strategy] = opts[:default_auth_strategy] if opts[:default_auth_strategy]

        # Enable authentication middleware if strategies are configured
        return unless opts[:auth_strategies] && !opts[:auth_strategies].empty?

      end

      def configure_mcp(opts)
        @mcp_server = nil

        # Enable MCP if requested in options
        return unless opts[:mcp_enabled] || opts[:mcp_http] || opts[:mcp_stdio]

        @mcp_server = Otto::MCP::Server.new(self)

        mcp_options = {}
        mcp_options[:http_endpoint] = opts[:mcp_endpoint] if opts[:mcp_endpoint]

        return unless opts[:mcp_http] != false # Default to true unless explicitly disabled

        @mcp_server.enable!(mcp_options)
      end

      # Configure locale settings for the application
      #
      # @param available_locales [Hash] Hash of available locales (e.g., { 'en' => 'English', 'es' => 'Spanish' })
      # @param default_locale [String] Default locale to use as fallback
      # @example
      #   otto.configure(
      #     available_locales: { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' },
      #     default_locale: 'en'
      #   )
      def configure(available_locales: nil, default_locale: nil)
        @locale_config ||= {}
        @locale_config[:available_locales] = available_locales if available_locales
        @locale_config[:default_locale] = default_locale if default_locale
      end

      # Configure rate limiting settings.
      #
      # @param config [Hash] Rate limiting configuration
      # @option config [Integer] :requests_per_minute Maximum requests per minute per IP
      # @option config [Hash] :custom_rules Hash of custom rate limiting rules
      # @option config [Object] :cache_store Custom cache store for rate limiting
      # @example
      #   otto.configure_rate_limiting({
      #     requests_per_minute: 50,
      #     custom_rules: {
      #       'api_calls' => { limit: 30, period: 60, condition: ->(req) { req.path.start_with?('/api') }}
      #     }
      #   })
      def configure_rate_limiting(config)
        @security_config.rate_limiting_config.merge!(config)
      end

      # Configure authentication strategies for route-level access control.
      #
      # @param strategies [Hash] Hash mapping strategy names to strategy instances
      # @param default_strategy [String] Default strategy to use when none specified
      # @example
      #   otto.configure_auth_strategies({
      #     'noauth' => Otto::Security::Authentication::Strategies::NoAuthStrategy.new,
      #     'authenticated' => Otto::Security::Authentication::Strategies::SessionStrategy.new(session_key: 'user_id'),
      #     'role:admin' => Otto::Security::Authentication::Strategies::RoleStrategy.new(['admin']),
      #     'api_key' => Otto::Security::Authentication::Strategies::APIKeyStrategy.new(api_keys: ['secret123'])
      #   })
      def configure_auth_strategies(strategies, default_strategy: 'noauth')
        # Update existing @auth_config rather than creating a new one
        @auth_config[:auth_strategies] = strategies
        @auth_config[:default_auth_strategy] = default_strategy

      end

      private

      def middleware_enabled?(middleware_class)
        # Only check the new middleware stack as the single source of truth
        @middleware && @middleware.includes?(middleware_class)
      end
    end
  end
end
