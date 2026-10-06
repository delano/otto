# lib/otto/mcp/route_parser.rb
#
# frozen_string_literal: true

require_relative '../route_definition'

class Otto
  module MCP
    # Parser for MCP route definitions and resource URIs
    class RouteParser
      def self.parse_mcp_route(_verb, _path, definition)
        # MCP route format: MCP resource_uri HandlerClass.method_name
        # Note: The path parameter is ignored for MCP routes - resource_uri comes from definition
        parts = definition.split(/\s+/, 3)

        raise ArgumentError, "Expected MCP keyword, got: #{parts[0]}" if parts[0] != 'MCP'

        resource_uri       = parts[1]
        handler_definition = parts[2]

        raise ArgumentError, "Invalid MCP route format: #{definition}" unless resource_uri && handler_definition

        # Clean up URI - remove leading slash if present since MCP URIs are relative
        resource_uri = resource_uri.sub(%r{^/}, '')

        {
          type: :mcp_resource,
          resource_uri: resource_uri,
          handler: handler_definition,
          options: extract_options_from_handler(handler_definition, "MCP route #{resource_uri.inspect}"),
        }
      end

      def self.parse_tool_route(_verb, _path, definition)
        # TOOL route format: TOOL tool_name HandlerClass.method_name
        # Note: The path parameter is ignored for TOOL routes - tool_name comes from definition
        parts = definition.split(/\s+/, 3)

        raise ArgumentError, "Expected TOOL keyword, got: #{parts[0]}" if parts[0] != 'TOOL'

        tool_name          = parts[1]
        handler_definition = parts[2]

        raise ArgumentError, "Invalid TOOL route format: #{definition}" unless tool_name && handler_definition

        # Clean up tool name - remove leading slash if present
        tool_name = tool_name.sub(%r{^/}, '')

        {
          type: :mcp_tool,
          tool_name: tool_name,
          handler: handler_definition,
          options: extract_options_from_handler(handler_definition, "TOOL route #{tool_name.inspect}"),
        }
      end

      def self.is_mcp_route?(definition)
        definition.start_with?('MCP ')
      end

      def self.is_tool_route?(definition)
        definition.start_with?('TOOL ')
      end

      def self.extract_options_from_handler(handler_definition, route_label = "handler #{handler_definition.inspect}")
        parts   = handler_definition.split(/\s+/)
        options = {}

        # First part is the handler class.method. The MCP server registers
        # resources and tools without running the auth, role or CSRF checks
        # that normal routes get, so an auth|role|csrf token here (in any
        # form or case) fails the load instead of registering the route as
        # if it were protected. Other tokens are parsed by
        # Otto::RouteDefinition exactly as for normal routes and returned in
        # :options, but Otto::MCP::Server reads only the resource URI or tool
        # name and the handler, so each one is logged as not applied.
        parts[1..]&.each do |part|
          if Otto::RouteDefinition::SECURITY_GATING_OPTIONS.include?(part.split('=', 2).first.to_s.downcase)
            raise Otto::RouteDefinitionError,
                  "#{route_label} sets #{part.inspect}, but auth, role and csrf options are not " \
                  'enforced on MCP or TOOL routes. Remove the option and use mcp_auth_tokens ' \
                  'to require a token for the MCP endpoint.'
          end

          pair = Otto::RouteDefinition.parse_option_token(part, "handler #{handler_definition.inspect}")
          if pair
            options[pair[0]] = pair[1]
            Otto.structured_log(:warn, 'MCP/tool route option not applied',
              { option: part, route: route_label })
          else
            Otto.structured_log(:warn, 'Malformed MCP/tool route option ignored',
              { option: part, handler: handler_definition })
          end
        end

        options
      end
    end
  end
end
