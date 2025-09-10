# frozen_string_literal: true
# lib/otto/mcp/server.rb

require_relative 'protocol'
require_relative 'registry'
require_relative 'route_parser'
require_relative 'auth/token'
require_relative 'validation'
require_relative 'rate_limiting'

class Otto
  module MCP
    class Server
      attr_reader :protocol, :otto_instance

      def initialize(otto_instance)
        @otto_instance = otto_instance
        @protocol      = Protocol.new(otto_instance)
        @enabled       = false
      end

      def enable!(options = {})
        @enabled              = true
        @http_endpoint        = options.fetch(:http_endpoint, '/_mcp')
        @auth_tokens          = options[:auth_tokens] || []
        @enable_validation    = options.fetch(:enable_validation, true)
        @enable_rate_limiting = options.fetch(:enable_rate_limiting, true)

        # Configure middleware
        configure_middleware(options)

        # Add MCP endpoint route to Otto
        add_mcp_endpoint_route

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

      def configure_middleware(_options)
        # Configure middleware in security-optimal order:
        # 1. Rate limiting (reject excessive requests early)
        # 2. Authentication (validate credentials before parsing)
        # 3. Validation (expensive JSON schema validation last)

        # Configure rate limiting first
        if @enable_rate_limiting
          @otto_instance.use Otto::MCP::RateLimitMiddleware, @otto_instance.security_config
          Otto.logger.debug '[MCP] Rate limiting enabled' if Otto.debug
        end

        # Configure authentication second
        if @auth_tokens.any?
          @auth                                   = Otto::MCP::Auth::TokenAuth.new(@auth_tokens)
          @otto_instance.security_config.mcp_auth = @auth
          @otto_instance.use Otto::MCP::Auth::TokenMiddleware
          Otto.logger.debug '[MCP] Token authentication enabled' if Otto.debug
        end

        # Configure validation last (most expensive)
        return unless @enable_validation

        @otto_instance.use Otto::MCP::ValidationMiddleware
        Otto.logger.debug '[MCP] Request validation enabled' if Otto.debug
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
          klass = Object.const_get(klass_name)
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
