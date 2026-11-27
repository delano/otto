# lib/otto/mcp/registry.rb
#
# frozen_string_literal: true

require 'json'

require_relative 'auth/context'
require_relative 'call'
require_relative 'errors'
require_relative 'tool'

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

      # @param scopes [Array<String>] scopes a caller must have to list and
      #   read this resource
      def register_resource(uri, name, description, mime_type, handler, scopes: [])
        @resources[uri] = {
          uri: uri,
          name: name,
          description: description,
          mimeType: mime_type,
          handler: handler,
          scopes: Tool.normalize_scopes(scopes, "MCP resource #{uri}"),
        }
      end

      # Register an undeclared tool: Otto advertises +input_schema+ but does
      # not check arguments against it, and returns the handler's value as
      # text. Use {#add_tool} for a tool whose schemas and scopes Otto enforces.
      def register_tool(name, description, input_schema, handler)
        @tools[name] = Tool.undeclared(name, description, input_schema, handler)
      end

      # @param tool [Otto::MCP::Tool] a declared tool
      # @raise [ArgumentError] if a tool with that name is already registered
      def add_tool(tool)
        raise ArgumentError, "MCP tool #{tool.name} is already registered" if @tools.key?(tool.name)

        @tools[tool.name] = tool
      end

      # @return [Boolean] true when any tool or resource requires a scope, so
      #   that what a caller can list depends on who the caller is
      def scoped?
        @tools.each_value.any? { |tool| !tool.scopes.empty? } ||
          @resources.each_value.any? { |resource| !resource[:scopes].empty? }
      end

      # No tool or resource can be added, replaced or removed afterwards.
      #
      # @return [self]
      def deep_freeze!
        @resources.each_value(&:freeze)
        @resources.freeze
        @tools.freeze
        freeze
      end

      # @param auth [Otto::MCP::Auth::Context, nil] the verified caller
      # @return [Array<Hash>] the resources that caller may read, in
      #   registration order
      def list_resources(auth = nil)
        @resources.values.filter_map do |resource|
          next unless permitted?(resource[:scopes], auth)

          {
            uri: resource[:uri],
            name: resource[:name],
            description: resource[:description],
            mimeType: resource[:mimeType],
          }
        end
      end

      # @param auth [Otto::MCP::Auth::Context, nil] the verified caller
      # @return [Array<Hash>] the tools that caller may call, in registration
      #   order
      def list_tools(auth = nil)
        @tools.values.select { |tool| tool.permits?(auth) }.map(&:listing)
      end

      # @param uri [String] resource URI
      # @param env [Hash, nil] Rack env of the MCP request, passed to a handler
      #   that takes one argument (see .resource_handler_args)
      # @raise [Otto::MCP::InsufficientScopeError] if the caller in
      #   +env['otto.mcp.auth']+ lacks a scope the resource requires
      def read_resource(uri, env = nil)
        resource = @resources[uri]
        return nil unless resource
        raise InsufficientScopeError, resource[:scopes] unless permitted?(resource[:scopes], caller_in(env))

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

      # Call a tool on behalf of the caller in +env['otto.mcp.auth']+.
      #
      # Every way of invoking a tool handler goes through here, so the scope
      # check and, for a declared tool, the schema checks cannot be skipped by
      # naming a tool that was left out of +tools/list+.
      #
      # @param name [String]
      # @param arguments [Hash]
      # @param env [Hash, nil] Rack env of the MCP request
      # @return [Hash, Otto::MCP::InputRequired] the tool result, or the
      #   handler's request for input
      # @raise [Otto::MCP::ToolNotFoundError] if no such tool is registered
      # @raise [Otto::MCP::InsufficientScopeError] if the caller lacks a scope
      #   the tool requires
      # @raise [Otto::MCP::OutputValidationError] if a declared tool's return
      #   value does not conform to its output schema
      def call_tool(name, arguments, env)
        tool = @tools[name]
        raise ToolNotFoundError, "Tool not found: #{name}" unless tool
        raise InsufficientScopeError, tool.scopes unless tool.permits?(caller_in(env))

        return text_result(tool.invoke(arguments, env)) unless tool.declared?

        violations = tool.input_violations(arguments)
        return error_result("Invalid arguments for tool #{name}: #{violations.join('; ')}") unless violations.empty?

        declared_result(tool, tool.invoke(arguments, env))
      rescue ToolError => e
        error_result(e.message)
      end

      private

      def caller_in(env)
        auth = env && env['otto.mcp.auth']
        auth if auth.is_a?(Otto::MCP::Auth::Context)
      end

      def permitted?(scopes, auth)
        scopes.empty? || (!auth.nil? && auth.grants?(scopes))
      end

      def text_result(value)
        return value if value.is_a?(InputRequired)

        { content: [{ type: 'text', text: value.to_s }] }
      end

      def error_result(message)
        { content: [{ type: 'text', text: message }], isError: true }
      end

      # With an output schema the value is the structured result: it is
      # reduced to JSON types, checked, and sent both as structuredContent and
      # as its JSON text. A value that fails the check is never sent.
      def declared_result(tool, value)
        return text_result(value) if value.is_a?(InputRequired) || tool.output_schema.nil?

        structured = JSON.parse(JSON.generate(value))
        violations = tool.output_violations(structured)
        raise OutputValidationError, violations unless violations.empty?

        { content: [{ type: 'text', text: JSON.generate(structured) }], structuredContent: structured }
      end
    end
  end
end
