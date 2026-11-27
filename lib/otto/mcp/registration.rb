# lib/otto/mcp/registration.rb
#
# frozen_string_literal: true

require_relative 'registry'
require_relative 'tool'
require_relative '../security/constant_resolver'

class Otto
  module MCP
    # How tools and resources reach an MCP server's registry: from +MCP+ and
    # +TOOL+ route lines, and from {#define_tool} and {#define_resource}.
    # Included in {Otto::MCP::Server}.
    module Registration
      def register_mcp_route(route_info)
        case route_info[:type]
        when :mcp_resource
          register_resource(route_info)
        when :mcp_tool
          register_tool(route_info)
        end
      end

      # Register a declared tool: one whose arguments, return value and
      # callers Otto checks on every call. See {Otto::MCP::Tool#initialize}
      # for the definition keywords.
      #
      # On a hosted endpoint +output_schema:+ and +scopes:+ must both be
      # given, so that nothing a tool returns is unchecked and no tool is
      # open to every caller by omission. +scopes: []+ states that any
      # authenticated caller may use the tool.
      #
      # @param name [String]
      # @param handler [#call, String, nil] takes +(arguments, env)+; the
      #   block when nil
      # @return [Otto::MCP::Tool]
      # @raise [ArgumentError] if the endpoint is not enabled, the definition
      #   is incomplete or invalid, the name is taken, or the tool requires
      #   scopes on an endpoint with no authenticator to grant them
      def define_tool(name, handler = nil, **definition, &block)
        require_enabled!("tool #{name}")
        require_hosted_keywords!("tool #{name}", definition, %i[output_schema scopes])

        tool = Tool.new(name: name, handler: handler || block, **definition)
        require_authenticator_for!("tool #{name}", tool.scopes)
        @protocol.registry.add_tool(tool)
      end

      # Register a resource from Ruby instead of from an +MCP+ route line,
      # with the scopes a caller needs to list and read it.
      #
      # @param uri [String]
      # @param handler [#call, nil] takes no argument or the Rack env; the
      #   block when nil
      # @param description [String]
      # @param name [String, nil] the last segment of the URI when nil
      # @param mime_type [String]
      # @param scopes [Array<String>, nil] required on a hosted endpoint
      # @return [void]
      # @raise [ArgumentError] as for {#define_tool}
      def define_resource(uri, handler = nil, description:, name: nil, mime_type: 'text/plain', **definition, &block)
        require_enabled!("resource #{uri}")
        require_hosted_keywords!("resource #{uri}", definition, %i[scopes])
        unknown = definition.keys - %i[scopes]
        raise ArgumentError, "Unknown MCP resource option(s): #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

        handler ||= block
        raise ArgumentError, "MCP resource #{uri} handler must respond to #call" unless handler.respond_to?(:call)

        scopes = Tool.normalize_scopes(definition[:scopes] || [], "MCP resource #{uri}")
        require_authenticator_for!("resource #{uri}", scopes)
        @protocol.registry.register_resource(uri, name || extract_name_from_uri(uri), description, mime_type, handler,
          scopes: scopes)
        nil
      end

      # Called when Otto freezes its configuration at the first request. From
      # then on the tools and resources, and the scopes and schemas that
      # guard them, cannot change.
      #
      # @return [void]
      # @api private
      def freeze_registry!
        @protocol.registry.deep_freeze!
      end

      private

      def require_enabled!(label)
        return if enabled?

        raise ArgumentError, "MCP #{label} cannot be registered before the endpoint is enabled. Call enable_mcp! first."
      end

      def require_hosted_keywords!(label, definition, keywords)
        missing = keywords.reject { |keyword| definition.key?(keyword) }
        return if !hosted? || missing.empty?

        raise ArgumentError,
              "MCP #{label} on a hosted endpoint must state #{missing.map { |keyword| "#{keyword}:" }.join(' and ')}. " \
              'scopes: [] admits every authenticated caller.'
      end

      def require_authenticator_for!(label, scopes)
        return if scopes.empty? || @authenticator

        raise ArgumentError,
              "MCP #{label} requires scopes #{scopes.join(', ')}, but this endpoint has no authenticator " \
              'to grant them, so no caller could ever use it. Enable MCP with authenticator:.'
      end

      # A hosted endpoint takes every tool and resource from define_tool and
      # define_resource, which state the schemas and scopes a route line has
      # no place for. Raising RouteDefinitionError stops the boot; the router
      # logs and drops any other error from an MCP or TOOL line.
      def refuse_route_line_when_hosted!(kind, name)
        return unless hosted?

        raise Otto::RouteDefinitionError,
              "#{kind} route #{name.inspect} cannot be loaded on a hosted MCP endpoint. " \
              "Register it with #{kind == 'TOOL' ? 'register_mcp_tool' : 'register_mcp_resource'}, " \
              'which states its schemas and scopes.'
      end

      def register_resource(route_info)
        uri         = route_info[:resource_uri]
        handler_def = route_info[:handler]
        refuse_route_line_when_hosted!('MCP', uri)

        # Parse handler definition
        klass_method = handler_def.split(/\s+/).first.split('.')
        klass_name   = klass_method[0..-2].join('::')
        method_name  = klass_method.last

        # Create resource handler. It receives the Rack env of the MCP request
        # from Registry#read_resource and passes it on when the class method
        # takes one argument, so a resource can check permissions per request.
        # A failure propagates to the protocol handler, which logs it.
        handler = lambda do |env|
          klass = Otto::Security::ConstantResolver.safe_const_get(klass_name)
          args  = Otto::MCP::Registry.resource_handler_args(
            klass.method(method_name), env, "Handler #{klass_name}.#{method_name} for resource #{uri}"
          )
          klass.public_send(method_name, *args)
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
        refuse_route_line_when_hosted!('TOOL', name)

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
  end
end
