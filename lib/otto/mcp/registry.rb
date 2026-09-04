# lib/otto/mcp/registry.rb
#
# frozen_string_literal: true

require_relative '../security/constant_resolver'
require_relative 'errors'

class Otto
  module MCP
    # Registry for managing MCP resources and tools
    class Registry
      def initialize
        @resources = {}
        @tools     = {}
      end

      def register_resource(uri, name, description, mime_type, handler)
        @resources[uri] = {
          uri: uri,
          name: name,
          description: description,
          mimeType: mime_type,
          handler: handler,
        }
      end

      def register_tool(name, description, input_schema, handler)
        @tools[name] = {
          name: name,
          description: description,
          inputSchema: input_schema,
          handler: handler,
        }
      end

      def list_resources
        @resources.values.map do |resource|
          {
            uri: resource[:uri],
            name: resource[:name],
            description: resource[:description],
            mimeType: resource[:mimeType],
          }
        end
      end

      def list_tools
        @tools.values.map do |tool|
          {
            name: tool[:name],
            description: tool[:description],
            inputSchema: tool[:inputSchema],
          }
        end
      end

      def read_resource(uri)
        resource = @resources[uri]
        return nil unless resource

        # A handler that blows up propagates: it is an execution fault
        # (-32603/500), not a missing resource (-32001/404). Returning nil
        # here previously made the two indistinguishable to the protocol,
        # which owns the logging (Protocol#handle_resources_read).
        content = resource[:handler].call
        {
          contents: [{
            uri: uri,
            mimeType: resource[:mimeType],
            text: content.to_s,
          }],
        }
      end

      def call_tool(name, arguments, env)
        tool = @tools[name]
        raise ToolNotFoundError, "Tool not found: #{name}" unless tool

        handler = tool[:handler]
        if handler.respond_to?(:call)
          result = handler.call(arguments, env)
        elsif handler.is_a?(String) && handler.include?('.')
          klass_method = handler.split('.')
          klass_name   = klass_method[0..-2].join('::')
          method_name  = klass_method.last

          klass  = Otto::Security::ConstantResolver.safe_const_get(klass_name)
          result = klass.public_send(method_name, arguments, env)
        else
          raise "Invalid tool handler: #{handler}"
        end

        {
          content: [{
            type: 'text',
            text: result.to_s,
          }],
        }
      end
    end
  end
end
