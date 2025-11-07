# lib/otto/mcp/route_parser.rb
#
# frozen_string_literal: true

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
          options: extract_options_from_handler(handler_definition),
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
          options: extract_options_from_handler(handler_definition),
        }
      end

      def self.is_mcp_route?(definition)
        definition.start_with?('MCP ')
      end

      def self.is_tool_route?(definition)
        definition.start_with?('TOOL ')
      end

      def self.extract_options_from_handler(handler_definition)
        parts   = handler_definition.split(/\s+/)
        options = {}

        # First part is the handler class.method
        parts[1..-1]&.each do |part|
          key, value = part.split('=', 2)
          options[key.to_sym] = value if key && value
        end

        options
      end
    end
  end
end
