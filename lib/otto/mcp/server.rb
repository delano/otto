# lib/otto/mcp/server.rb
#
# frozen_string_literal: true

require 'securerandom'

require_relative 'protocol'
require_relative 'registry'
require_relative 'route_parser'
require_relative 'auth/bearer'
require_relative 'auth/token'
require_relative 'origin_guard'
require_relative 'request_state'
require_relative 'schema_validation'
require_relative 'rate_limiting'
require_relative 'registration'
require_relative 'options'
require_relative 'settings'
require_relative '../security/constant_resolver'
require_relative '../core/redacted_inspect'

class Otto
  module MCP
    # MCP server implementation providing Model Context Protocol endpoints
    class Server
      include Otto::Core::RedactedInspect
      include Otto::MCP::Registration

      attr_reader :protocol, :otto_instance

      # The document this endpoint publishes so an OAuth client can find its
      # authorization servers (RFC 9728), or nil when the endpoint was not
      # given a resource URI. Otto serves it at the well-known path beside
      # the endpoint. An application mounted under a path prefix serves this
      # Hash itself from the well-known path at the root of its origin.
      #
      # @return [Hash, nil] frozen, String-keyed
      attr_reader :protected_resource_metadata

      # Normalize raw options into the canonical MCP option hash.
      #
      # @param opts [Hash] raw options
      # @param scope [Symbol] :explicit (strict, for #enable_mcp!) or
      #   :constructor (ignores non-MCP keys, for Otto.new)
      # @see Otto::MCP::Options.normalize
      def self.normalize_options(opts = {}, scope = :explicit)
        Otto::MCP::Options.normalize(opts, scope)
      end

      def initialize(otto_instance)
        @otto_instance = otto_instance
        @protocol      = Protocol.new(otto_instance)
        @enabled       = false
      end

      # Warning emitted when the MCP HTTP endpoint is exposed with no token
      # authentication. Unconditional (not gated on Otto.debug): an
      # unauthenticated MCP endpoint lets any caller invoke every registered
      # tool, so it must be visible in normal boot output.
      UNAUTHENTICATED_WARNING = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        [MCP] HTTP endpoint %s is enabled without authentication:
        any caller can list and invoke MCP tools and resources.
        Pass auth_tokens: ['<token>'] to require a bearer token, or
        allow_unauthenticated: true to acknowledge this intentionally.
      MSG

      # Logged the first time an endpoint issues a requestState under a key it
      # generated for itself.
      GENERATED_STATE_SECRET_WARNING = <<~MSG.gsub(/\s+/, ' ').strip.freeze
        [MCP] request_state_secret is not set, so this process generated its
        own key. A client that retries a call on another process, or after a
        restart, will have its requestState refused. Set request_state_secret
        to a stable value of at least 32 bytes.
      MSG

      # Enable the MCP server.
      #
      # Enabling is one-shot. Each call appends a route, an endpoint-setting
      # proc and the MCP middleware to the Otto instance without removing the
      # previous set, so a second call with a different endpoint would leave
      # the first endpoint routed but guarded by nothing (the auth middleware
      # only matches the newest endpoint). Rather than try to unwind that,
      # a second call raises.
      #
      # @param options [Hash] canonical or aliased options; normalized via
      #   {.normalize_options}, so both the canonical keys (:http_endpoint,
      #   :auth_tokens, ...) and their mcp_-prefixed spellings
      #   (:mcp_endpoint, :mcp_auth_tokens, ...) are accepted.
      # @raise [ArgumentError] if the server is already enabled
      def enable!(options = {})
        if @enabled
          raise ArgumentError,
                "MCP server is already enabled on #{@http_endpoint}; pass all MCP options " \
                'in a single Otto.new or enable_mcp! call'
        end

        options = self.class.normalize_options(options)

        Validator.ensure_available! if options[:enable_validation]
        Otto::Security::RateLimiting.ensure_available! if options[:enable_rate_limiting]

        @enabled               = true
        @http_endpoint         = options[:http_endpoint]
        @auth_tokens           = Otto::Core::RedactedInspect.secret(options[:auth_tokens])
        @enable_validation     = options[:enable_validation]
        @enable_rate_limiting  = options[:enable_rate_limiting]
        @allow_unauthenticated = options[:allow_unauthenticated]
        @hosted                = options.fetch(:hosted, false)
        @authenticator         = build_authenticator(options)

        @protected_resource_metadata = build_protected_resource_metadata(options)
        @protocol.configure(build_settings(options))

        # An endpoint that serves 2026-07-28 checks Origin, as that revision
        # requires. One that serves only 2024-11-05 checks it when
        # allowed_origins is set, and otherwise behaves as it always has.
        @allowed_origins = options.fetch(:allowed_origins, []) if @protocol.settings.modern? || options.key?(:allowed_origins)

        apply_rate_limits(options)

        # Configure middleware
        configure_middleware(options)

        # Add MCP endpoint route to Otto
        add_mcp_endpoint_route
        add_protected_resource_metadata_route

        warn_if_unauthenticated!

        Otto.logger.info "[MCP] Server enabled with HTTP endpoint: #{@http_endpoint}" if Otto.debug
      end

      def enabled?
        @enabled
      end

      # @return [Boolean] true when the endpoint was enabled with
      #   +hosted: true+
      def hosted?
        @hosted == true
      end

      private

      # #inspect shows the bearer tokens as [REDACTED] with their count.
      def redacted_inspect_value(ivar, value)
        ivar == :@auth_tokens ? redacted_placeholder(value) : super
      end

      # Publish the per-minute limits under the keys RateLimitMiddleware /
      # RateLimiter.configure_rack_attack! already read, via Otto's sanctioned
      # rate-limiting configuration entry point. Before this, the values passed
      # to enable! were dead and the hardcoded 60/20 always won.
      #
      # The endpoint travels with them. Rack::Attack is mounted by the host app
      # OUTSIDE Otto and runs before any of Otto's middleware, so the
      # env['otto.mcp_http_endpoint'] set by add_mcp_endpoint_route is not yet
      # present when the throttles are evaluated; without this, a custom
      # endpoint was compared against the '/_mcp' fallback and never throttled.
      def apply_rate_limits(options)
        return unless @enable_rate_limiting

        @otto_instance.configure_rate_limiting(
          mcp_http_endpoint: @http_endpoint,
          mcp_requests_per_minute: options[:requests_per_minute],
          tool_calls_per_minute: options[:tools_per_minute]
        )
      end

      def warn_if_unauthenticated!
        return if @auth_tokens.any? || @authenticator || @allow_unauthenticated

        Otto.logger.warn format(UNAUTHENTICATED_WARNING, @http_endpoint)
      end

      def configure_middleware(_options)
        # Target EXECUTION order (outermost first, i.e. what a request meets in
        # turn), security-optimal:
        #   1. Rate limiting  — shed excessive load before spending any work
        #   2. Origin check   — one header, when the endpoint validates Origin
        #   3. Authentication — reject anonymous callers before parsing bodies
        #   4. Validation     — expensive JSON schema check only on requests
        #                       that already proved themselves
        #
        # MiddlewareStack stores entries in the REVERSE of execution order
        # (#wrap folds with reduce, so a later array entry is a further-out
        # wrapper). Registration therefore runs innermost-first: validation is
        # pinned :innermost, then auth is appended, then the origin check,
        # then rate limiting. The previous code read the positions as
        # execution order and produced the exact inverse — validation ran
        # ahead of auth, so unauthenticated callers reached the schema
        # validator.

        middleware = @otto_instance.instance_variable_get(:@middleware)

        # Innermost (last to execute): schema validation, closest to the app.
        if @enable_validation
          middleware.add_with_position(
            Otto::MCP::SchemaValidationMiddleware,
            position: :innermost
          )
          Otto.logger.debug '[MCP] Schema validation enabled (executes last)' if Otto.debug
        end

        # Middle: authentication, outside validation and inside rate limiting.
        if @authenticator || @auth_tokens.any?
          @auth = @authenticator || Otto::MCP::Auth::TokenAuth.new(@auth_tokens)
          @otto_instance.security_config.mcp_auth = @auth
          # Pass security_config explicitly: TokenMiddleware is not in
          # MiddlewareStack#middleware_needs_config?, so #wrap would build it
          # with a nil config and — now that the middleware fails closed —
          # reject every request, valid token included.
          @otto_instance.use Otto::MCP::Auth::TokenMiddleware, @otto_instance.security_config
          Otto.logger.debug '[MCP] Token authentication enabled (executes after rate limiting)' if Otto.debug
        end

        # Outside authentication: the Origin check.
        if @allowed_origins
          @otto_instance.use Otto::MCP::OriginGuard, @http_endpoint, @allowed_origins
          Otto.logger.debug '[MCP] Origin validation enabled (executes before authentication)' if Otto.debug
        end

        # Outermost of the three (first to execute): rate limiting.
        if @enable_rate_limiting
          middleware.add_with_position(
            Otto::MCP::RateLimitMiddleware,
            @otto_instance.security_config,
            position: :last
          )
          Otto.logger.debug '[MCP] Rate limiting enabled (executes first)' if Otto.debug
        end

        # Validate execution order (should pass with the positioning above).
        warnings = middleware.validate_mcp_middleware_order
        warnings.each { |warning| Otto.logger.warn warning }
      end

      def add_mcp_endpoint_route
        add_literal_route('POST', @http_endpoint, 'Otto::MCP::InternalHandler.handle_request')

        # 2026-07-28 has no GET stream and no session to DELETE. A client of
        # an earlier revision that tries either is told so with 405.
        if @protocol.settings.modern?
          %w[GET DELETE].each do |verb|
            add_literal_route(verb, @http_endpoint, 'Otto::MCP::InternalHandler.method_not_allowed')
          end
        end

        # Ensure env carries endpoint for middlewares. Close over a local copy:
        # the proc must keep announcing the endpoint it was registered for even
        # if the ivar is ever reassigned.
        endpoint = @http_endpoint
        @otto_instance.use proc { |app|
          lambda { |env|
            env['otto.mcp_http_endpoint'] = endpoint
            app.call(env)
          }
        }
      end

      # Keyed by the normalized path, as the router keys every literal route
      # and normalizes PATH_INFO before the lookup: a configured trailing
      # slash ('/a/') or the root ('/') otherwise registers a key the lookup
      # can never hit, while Otto::MCP.endpoint_path? still claims the path.
      def add_literal_route(verb, path, definition)
        route      = Otto::Route.new(verb, path, definition)
        route.otto = @otto_instance

        key = verb.to_sym
        @otto_instance.routes[key] ||= []
        @otto_instance.routes[key] << route
        @otto_instance.routes_literal[key] ||= {}
        @otto_instance.routes_literal[key][Otto::Utils.normalize_path(path)] = route
      end

      # The metadata document sits at the well-known path followed by the
      # endpoint path, which is where a client looks when the endpoint's
      # resource URI has that path and the application is mounted at the root.
      def add_protected_resource_metadata_route
        return unless @protected_resource_metadata

        endpoint = Otto::Utils.normalize_path(@http_endpoint)
        add_literal_route('GET', Auth::Challenge::WELL_KNOWN_PATH + (endpoint == '/' ? '' : endpoint),
          'Otto::MCP::InternalHandler.protected_resource_metadata')
      end

      def build_authenticator(options)
        return nil unless options[:authenticator]

        Auth::BearerAuth.new(options[:authenticator],
          resource_uri: options[:resource_uri],
          challenge_scopes: options.fetch(:scopes_supported, []))
      end

      def build_protected_resource_metadata(options)
        return nil unless options[:resource_uri]

        {
          'resource' => options[:resource_uri],
          'authorization_servers' => options[:authorization_servers],
          'scopes_supported' => options[:scopes_supported],
          'bearer_methods_supported' => ['header'].freeze,
        }.compact.freeze
      end

      def build_settings(options)
        defaults = Settings.legacy
        versions = options.fetch(:protocol_versions, defaults.protocol_versions)

        Settings.new(
          protocol_versions: versions,
          hosted: hosted?,
          auth: @authenticator,
          server_info: options.fetch(:server_info, defaults.server_info),
          instructions: options[:instructions],
          cache_ttl_ms: options.fetch(:cache_ttl_ms, defaults.cache_ttl_ms),
          request_state: (build_request_state(options[:request_state_secret]) if versions.intersect?(MODERN_PROTOCOL_VERSIONS))
        )
      end

      def build_request_state(secret)
        return RequestState.new(secret) if secret

        RequestState.new(SecureRandom.random_bytes(32),
          on_first_seal: -> { Otto.logger.warn GENERATED_STATE_SECRET_WARNING })
      end
    end

    # Internal handler class for MCP protocol endpoints
    class InternalHandler
      def self.handle_request(req, res)
        mcp_server, refusal = server_for_request
        return refusal if refusal

        status, headers, body = mcp_server.protocol.handle_request(req.env)

        res.status                   = status
        headers.each { |k, v| res[k] = v }
        res.body                     = body
        res.finish
      end

      # GET and DELETE on an endpoint that serves 2026-07-28.
      def self.method_not_allowed(_req, res)
        _mcp_server, refusal = server_for_request
        return refusal if refusal

        error               = { code: -32_600, message: 'Invalid Request', data: 'Send JSON-RPC requests with POST' }
        res.status          = 405
        res['allow']        = 'POST'
        res['content-type'] = 'application/json'
        res.body            = [JSON.generate({ jsonrpc: '2.0', error: error })]
        res.finish
      end

      # The OAuth protected resource metadata document. It is public: a
      # client reads it before it has a token.
      def self.protected_resource_metadata(_req, res)
        mcp_server, refusal = server_for_request
        return refusal if refusal

        res.status          = 200
        res['content-type'] = 'application/json'
        res.body            = [JSON.generate(mcp_server.protected_resource_metadata)]
        res.finish
      end

      # @return [Array] the MCP server of the Otto that dispatched this
      #   request and nil, or nil and the response to send instead
      def self.server_for_request
        # The route dispatcher binds its owning Otto to this request's fiber.
        otto_instance = otto if respond_to?(:otto)

        if otto_instance.nil?
          return [nil, [500, { 'content-type' => 'application/json' },
                        [JSON.generate({ error: 'Otto instance not available' })]]]
        end

        mcp_server = otto_instance.mcp_server
        return [mcp_server, nil] if mcp_server&.enabled?

        [nil, [404, { 'content-type' => 'application/json' }, [JSON.generate({ error: 'MCP not enabled' })]]]
      end
      private_class_method :server_for_request
    end
  end
end
