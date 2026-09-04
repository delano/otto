# lib/otto/mcp/server.rb
#
# frozen_string_literal: true

require_relative 'protocol'
require_relative 'registry'
require_relative 'route_parser'
require_relative 'auth/token'
require_relative 'schema_validation'
require_relative 'rate_limiting'
require_relative 'options'
require_relative '../security/constant_resolver'

class Otto
  module MCP
    # MCP server implementation providing Model Context Protocol endpoints
    class Server
      attr_reader :protocol, :otto_instance

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

      # Enable the MCP server.
      #
      # @param options [Hash] canonical or aliased options; normalized via
      #   {.normalize_options}, so both the canonical keys (:http_endpoint,
      #   :auth_tokens, ...) and their mcp_-prefixed spellings
      #   (:mcp_endpoint, :mcp_auth_tokens, ...) are accepted.
      def enable!(options = {})
        options = self.class.normalize_options(options)

        @enabled               = true
        @http_endpoint         = options[:http_endpoint]
        @auth_tokens           = options[:auth_tokens]
        @enable_validation     = options[:enable_validation]
        @enable_rate_limiting  = options[:enable_rate_limiting]
        @allow_unauthenticated = options[:allow_unauthenticated]

        apply_rate_limits(options)

        # Configure middleware
        configure_middleware(options)

        # Add MCP endpoint route to Otto
        add_mcp_endpoint_route

        warn_if_unauthenticated!

        Otto.logger.info "[MCP] Server enabled with HTTP endpoint: #{@http_endpoint}" if Otto.debug
      end

      def enabled?
        @enabled
      end

      def register_mcp_route(route_info)
        case route_info[:type]
        when :mcp_resource
          register_resource(route_info)
        when :mcp_tool
          register_tool(route_info)
        end
      end

      private

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
        return if @auth_tokens.any? || @allow_unauthenticated

        Otto.logger.warn format(UNAUTHENTICATED_WARNING, @http_endpoint)
      end

      def configure_middleware(_options)
        # Target EXECUTION order (outermost first, i.e. what a request meets in
        # turn), security-optimal:
        #   1. Rate limiting  — shed excessive load before spending any work
        #   2. Authentication — reject anonymous callers before parsing bodies
        #   3. Validation     — expensive JSON schema check only on requests
        #                       that already proved themselves
        #
        # MiddlewareStack stores entries in the REVERSE of execution order
        # (#wrap folds with reduce, so a later array entry is a further-out
        # wrapper). Registration therefore runs innermost-first: validation is
        # pinned :innermost, then auth is appended, then rate limiting. The
        # previous code read the positions as execution order and produced the
        # exact inverse — validation ran ahead of auth, so unauthenticated
        # callers reached the schema validator.

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
        if @auth_tokens.any?
          @auth = Otto::MCP::Auth::TokenAuth.new(@auth_tokens)
          @otto_instance.security_config.mcp_auth = @auth
          # Pass security_config explicitly: TokenMiddleware is not in
          # MiddlewareStack#middleware_needs_config?, so #wrap would build it
          # with a nil config and — now that the middleware fails closed —
          # reject every request, valid token included.
          @otto_instance.use Otto::MCP::Auth::TokenMiddleware, @otto_instance.security_config
          Otto.logger.debug '[MCP] Token authentication enabled (executes after rate limiting)' if Otto.debug
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
        InternalHandler.otto_instance = @otto_instance

        mcp_route      = Otto::Route.new('POST', @http_endpoint, 'Otto::MCP::InternalHandler.handle_request')
        mcp_route.otto = @otto_instance

        @otto_instance.routes[:POST] ||= []
        @otto_instance.routes[:POST] << mcp_route

        @otto_instance.routes_literal[:POST]               ||= {}
        @otto_instance.routes_literal[:POST][@http_endpoint] = mcp_route

        # Ensure env carries endpoint for middlewares
        @otto_instance.use proc { |app|
          lambda { |env|
            env['otto.mcp_http_endpoint'] = @http_endpoint
            app.call(env)
          }
        }
      end

      def register_resource(route_info)
        uri         = route_info[:resource_uri]
        handler_def = route_info[:handler]

        # Parse handler definition
        klass_method = handler_def.split(/\s+/).first.split('.')
        klass_name   = klass_method[0..-2].join('::')
        method_name  = klass_method.last

        # Create resource handler
        handler = lambda do
          klass = Otto::Security::ConstantResolver.safe_const_get(klass_name)
          method = klass.method(method_name)
          if method.arity != 0
            raise ArgumentError, "Handler #{klass_name}.#{method_name} must be a zero-arity method for resource #{uri}"
          end

          klass.public_send(method_name)
        rescue StandardError => e
          Otto.logger.error "[MCP] Resource handler error for #{uri}: #{e.message}"
          raise
        end

        # Register with protocol registry
        @protocol.registry.register_resource(
          uri,
          extract_name_from_uri(uri),
          "Resource: #{uri}",
          'text/plain',
          handler
        )

        Otto.logger.debug "[MCP] Registered resource: #{uri} -> #{handler_def}" if Otto.debug
      end

      def register_tool(route_info)
        name        = route_info[:tool_name]
        handler_def = route_info[:handler]

        # Parse handler definition
        klass_method = handler_def.split(/\s+/).first.split('.')
        klass_name   = klass_method[0..-2].join('::')
        method_name  = klass_method.last

        # Create input schema - basic for now
        input_schema = {
          type: 'object',
          properties: {},
          required: [],
        }

        # Register with protocol registry
        @protocol.registry.register_tool(
          name,
          "Tool: #{name}",
          input_schema,
          "#{klass_name}.#{method_name}"
        )

        Otto.logger.debug "[MCP] Registered tool: #{name} -> #{handler_def}" if Otto.debug
      end

      def extract_name_from_uri(uri)
        uri.split('/').last || uri
      end
    end

    # Internal handler class for MCP protocol endpoints
    class InternalHandler
      @otto_instance = nil

      class << self
        attr_writer :otto_instance
      end

      class << self
        attr_reader :otto_instance
      end

      def self.handle_request(req, res)
        otto_instance = @otto_instance

        if otto_instance.nil?
          return [500, { 'content-type' => 'application/json' },
                  [JSON.generate({ error: 'Otto instance not available' })]]
        end

        mcp_server = otto_instance.mcp_server

        unless mcp_server&.enabled?
          return [404, { 'content-type' => 'application/json' },
                  [JSON.generate({ error: 'MCP not enabled' })]]
        end

        status, headers, body = mcp_server.protocol.handle_request(req.env)

        res.status                   = status
        headers.each { |k, v| res[k] = v }
        res.body                     = body
        res.finish
      end
    end
  end
end
