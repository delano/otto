class Otto
  module MCP
    class RouteParser
      def self.parse_mcp_route(verb, path, definition)
        # MCP route format: MCP resource_uri HandlerClass.method_name
        # Note: The path parameter is ignored for MCP routes - resource_uri comes from definition
        parts = definition.split(/\s+/, 3)

        if parts[0] != 'MCP'
          raise ArgumentError, "Expected MCP keyword, got: #{parts[0]}"
        end

        resource_uri = parts[1]
        handler_definition = parts[2]

        unless resource_uri && handler_definition
          raise ArgumentError, "Invalid MCP route format: #{definition}"
        end

        # Clean up URI - remove leading slash if present since MCP URIs are relative
        resource_uri = resource_uri.sub(/^\//, '')

        {
          type: :mcp_resource,
          resource_uri: resource_uri,
          handler: handler_definition,
          options: extract_options_from_handler(handler_definition)
        }
      end

      def self.parse_tool_route(verb, path, definition)
        # TOOL route format: TOOL tool_name HandlerClass.method_name
        # Note: The path parameter is ignored for TOOL routes - tool_name comes from definition
        parts = definition.split(/\s+/, 3)

        if parts[0] != 'TOOL'
          raise ArgumentError, "Expected TOOL keyword, got: #{parts[0]}"
        end

        tool_name = parts[1]
        handler_definition = parts[2]

        unless tool_name && handler_definition
          raise ArgumentError, "Invalid TOOL route format: #{definition}"
        end

        # Clean up tool name - remove leading slash if present
        tool_name = tool_name.sub(/^\//, '')

        {
          type: :mcp_tool,
          tool_name: tool_name,
          handler: handler_definition,
          options: extract_options_from_handler(handler_definition)
        }
      end

      def self.is_mcp_route?(definition)
        definition.start_with?('MCP ')
      end

      def self.is_tool_route?(definition)
        definition.start_with?('TOOL ')
      end

      private

      def self.extract_options_from_handler(handler_definition)
        parts = handler_definition.split(/\s+/)
        options = {}

        # First part is the handler class.method
        parts[1..-1]&.each do |part|
          key, value = part.split('=', 2)
          if key && value
            options[key.to_sym] = value
          end
        end

        options
      end
    end
  end
end
