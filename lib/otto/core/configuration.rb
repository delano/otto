# lib/otto/core/configuration.rb
#
# frozen_string_literal: true

require_relative '../security/csrf'
require_relative '../security/validator'
require_relative '../security/authentication'
require_relative '../security/rate_limiting'
require_relative '../mcp/server'
require_relative 'freezable'

class Otto
  module Core
    # Configuration module providing locale and application configuration methods
    module Configuration
      include Otto::Core::Freezable

      def configure_locale(opts)
        # Check if we have any locale configuration
        has_direct_options = opts[:available_locales] || opts[:default_locale]
        has_legacy_config = opts[:locale_config]

        # Only create locale_config if we have configuration
        return unless has_direct_options || has_legacy_config

        # Initialize with direct options
        available_locales = opts[:available_locales]
        default_locale = opts[:default_locale]

        # Legacy support: Configure locale if provided via locale_config hash
        if opts[:locale_config]
          locale_opts = opts[:locale_config]
          available_locales ||= locale_opts[:available_locales] || locale_opts[:available]
          default_locale ||= locale_opts[:default_locale] || locale_opts[:default]
        end

        # Create Otto::Locale::Config instance
        @locale_config = Otto::Locale::Config.new(
          available_locales: available_locales,
          default_locale: default_locale
        )
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

        # Set count-based trusted-proxy depth if provided (mutually exclusive
        # with trusted_proxies; conflict validated at configuration freeze).
        # Guard on presence (`unless nil?`), not truthiness, so an explicitly
        # provided invalid value (e.g. `false`) reaches the validating setter
        # and fails loud instead of being silently dropped.
        @security_config.trusted_proxy_depth = opts[:trusted_proxy_depth] unless opts[:trusted_proxy_depth].nil?

        # Select the forwarded header depth mode reads from ('X-Forwarded-For',
        # 'Forwarded', or 'Both'). Only consulted in depth mode. Same presence
        # guard: a provided-but-invalid value is validated, not ignored.
        @security_config.trusted_proxy_header = opts[:trusted_proxy_header] unless opts[:trusted_proxy_header].nil?

        # Set custom security headers
        return unless opts[:security_headers]

        set_security_headers(opts[:security_headers])
      end

      def configure_authentication(opts)
        # Update existing @auth_config rather than creating a new one
        # to maintain synchronization with the configurator
        @auth_config[:auth_strategies] = opts[:auth_strategies] if opts[:auth_strategies]
        @auth_config[:default_auth_strategy] = opts[:default_auth_strategy] if opts[:default_auth_strategy]

        # No-op: authentication strategies are configured via @auth_config above
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

      # Validate and freeze the lambda handler registry supplied at construction
      # (issue #41, AC#3). Security: only pre-registered callables are accepted;
      # nothing from route files reaches here, so no eval / dynamic code (AC#8).
      def configure_lambda_handlers(opts)
        @option[:lambda_handlers] = validate_lambda_handlers!(opts[:lambda_handlers])
      end

      # @raise [ArgumentError] naming the offending handler on any invalid entry
      # @return [Hash] frozen registry ({}.freeze when none supplied)
      def validate_lambda_handlers!(handlers)
        return {}.freeze if handlers.nil?

        unless handlers.is_a?(Hash)
          raise ArgumentError,
                "Otto :lambda_handlers must be a Hash of name => callable, got #{handlers.class}"
        end

        handlers.each do |name, handler|
          unless handler.respond_to?(:call)
            raise ArgumentError,
                  "Lambda handler '#{name}' is not callable (expected an object " \
                  "responding to #call, got #{handler.class})"
          end

          next if lambda_handler_accepts_three?(handler)

          raise ArgumentError,
                "Lambda handler '#{name}' has invalid arity " \
                '(must accept 3 arguments: req, res, extra_params)'
        end

        handlers.freeze
      end

      # True if +handler+ can be invoked with exactly three positional arguments.
      #
      # Reflects on the callable's #parameters rather than #arity so that:
      #   * non-Proc/Method callables (a plain object with #call) are supported
      #     without ever calling #arity, which they need not define (BUG A); and
      #   * optional-arg forms that cannot actually take 3 positional args are
      #     rejected instead of blanket-accepted by a negative arity (BUG B) --
      #     e.g. ->(a=1){} (accepts 0..1) and ->(a,b=1){} (accepts 1..2).
      #
      # Accepts req/opt/rest combinations that admit 3 positionals; rejects
      # anything requiring more than 3 or unable to reach 3.
      #
      # @api private
      # @return [Boolean]
      def lambda_handler_accepts_three?(handler)
        callable =
          if handler.is_a?(Proc) || handler.is_a?(Method)
            handler
          else
            handler.method(:call)
          end
        params   = callable.parameters
        required = params.count { |(type, _)| type == :req }
        optional = params.count { |(type, _)| type == :opt }
        has_rest = params.any?  { |(type, _)| type == :rest }

        return false if required > 3

        has_rest || (required + optional) >= 3
      rescue NameError, NoMethodError
        # A pathological callable whose #method(:call) reflection blows up still
        # yields a clean, handler-named ArgumentError from the caller.
        false
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
        ensure_not_frozen!

        # Initialize locale_config if not already set
        @locale_config ||= Otto::Locale::Config.new

        # Update configuration
        @locale_config.available_locales = available_locales if available_locales
        @locale_config.default_locale = default_locale if default_locale
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
        ensure_not_frozen!
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
        ensure_not_frozen!
        # Update existing @auth_config rather than creating a new one
        @auth_config[:auth_strategies] = strategies
        @auth_config[:default_auth_strategy] = default_strategy
      end

      # Freeze the application configuration to prevent runtime modifications.
      # Called automatically at the end of initialization to ensure immutability.
      #
      # This prevents security-critical configuration from being modified after
      # the application begins handling requests. Uses deep freezing to prevent
      # both direct modification and modification through nested structures.
      #
      # @raise [RuntimeError] if configuration is already frozen
      # @return [self]
      def freeze_configuration!
        if frozen_configuration?
          Otto.structured_log(:debug, 'Configuration already frozen', { status: 'skipped' }) if Otto.debug
          return self
        end

        start_time = Otto::Utils.now_in_μs

        # Deep freeze configuration objects with memoization support
        @security_config.deep_freeze! if @security_config.respond_to?(:deep_freeze!)
        @locale_config.deep_freeze! if @locale_config.respond_to?(:deep_freeze!)
        @middleware.deep_freeze! if @middleware.respond_to?(:deep_freeze!)

        # Deep freeze configuration hashes (recursively freezes nested structures)
        deep_freeze_value(@auth_config) if @auth_config
        deep_freeze_value(@option) if @option

        # Validate registered handler-wrapper factories against every loaded
        # route before locking the config. Surfaces TypeError / factory bugs
        # at boot instead of on the first request that happens to match.
        validate_handler_wrappers!

        # Deep freeze route structures (prevent modification of nested hashes/arrays)
        deep_freeze_value(@routes) if @routes
        deep_freeze_value(@routes_literal) if @routes_literal
        deep_freeze_value(@routes_static) if @routes_static
        deep_freeze_value(@route_definitions) if @route_definitions

        @configuration_frozen = true

        duration = Otto::Utils.now_in_μs - start_time
        frozen_objects = %w[security_config locale_config middleware auth_config option routes]
        Otto.structured_log(:info, 'Freezing completed',
          {
                  duration: duration,
            frozen_objects: frozen_objects.join(','),
          })

        self
      end

      # Check if configuration is frozen
      #
      # @return [Boolean] true if configuration is frozen
      def frozen_configuration?
        @configuration_frozen == true
      end

      # Ensure configuration is not frozen before allowing mutations
      #
      # @raise [FrozenError] if configuration is frozen
      def ensure_not_frozen!
        raise FrozenError, 'Cannot modify frozen configuration' if frozen_configuration?
      end

      def middleware_enabled?(middleware_class)
        # Only check the new middleware stack as the single source of truth
        @middleware&.includes?(middleware_class)
      end

      # Walk every loaded route and exercise the registered handler-wrapper
      # factories against a sentinel inner handler. Each factory must return a
      # callable; HandlerFactory.apply_handler_wrappers raises TypeError
      # otherwise. The constructed chain is discarded — this is a fail-fast
      # validation pass, not memoization.
      #
      # Iterates @routes (covers MCP routes added directly) uniquified by
      # identity. No-op if no wrappers are registered or no routes are loaded.
      #
      # @api private
      # @return [void]
      def validate_handler_wrappers!
        return unless @routes && @route_handler_factory
        return if @handler_wrappers.nil? || @handler_wrappers.empty?

        sentinel = ->(_env, _extra = {}) { [200, {}, []] }
        seen = {}.compare_by_identity
        @routes.each_value do |routes_for_verb|
          routes_for_verb.each do |route|
            next if seen[route]

            seen[route] = true
            Otto::RouteHandlers::HandlerFactory.apply_handler_wrappers(
              sentinel, route.route_definition, self
            )
          end
        end
      end
    end
  end
end
