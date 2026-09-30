# lib/otto/mcp/registry.rb
#
# frozen_string_literal: true

require_relative '../security/constant_resolver'
require_relative 'errors'

class Otto
  module MCP
    # Registry for managing MCP resources and tools
    class Registry
      POSITIONAL_PARAMETER_TYPES = %i[req opt rest].freeze

      # Arguments to call a resource handler with: the Rack env of the MCP
      # request when the handler takes a positional argument, nothing when it
      # takes none, so zero-argument handlers keep working. Reflects on
      # #parameters rather than #arity: +->(env = nil) {}+ has arity -1.
      #
      # @param callable [Proc, Method, #call] the handler, or the Method it calls
      # @param env [Hash, nil] Rack env of the MCP request
      # @param label [String] names the handler in the error message
      # @return [Array] +[]+ or +[env]+
      # @raise [ArgumentError] if the handler requires more than one positional
      #   argument or any keyword argument
      def self.resource_handler_args(callable, env, label)
        callable = callable.method(:call) unless callable.is_a?(Proc) || callable.is_a?(Method)
        params   = callable.parameters
        unusable = params.count { |(type, _)| type == :req } > 1 || params.any? { |(type, _)| type == :keyreq }
        raise ArgumentError, "#{label} must take no arguments or one (the Rack env)" if unusable

        params.any? { |(type, _)| POSITIONAL_PARAMETER_TYPES.include?(type) } ? [env] : []
      end

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

      # @param uri [String] resource URI
      # @param env [Hash, nil] Rack env of the MCP request, passed to a handler
      #   that takes one argument (see .resource_handler_args)
      def read_resource(uri, env = nil)
        resource = @resources[uri]
        return nil unless resource

        # A handler that blows up propagates: it is an execution fault
        # (-32603/500), not a missing resource (-32001/404). Returning nil
        # here previously made the two indistinguishable to the protocol,
        # which owns the logging (Protocol#handle_resources_read).
        handler = resource[:handler]
        content = handler.call(*self.class.resource_handler_args(handler, env, "Resource handler for #{uri}"))
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
