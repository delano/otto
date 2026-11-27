# lib/otto/mcp/tool.rb
#
# frozen_string_literal: true

require 'json'

require_relative '../security/constant_resolver'
require_relative 'schema_validation'

class Otto
  module MCP
    # One tool an MCP endpoint offers: what clients are told about it, what
    # may be passed to it, what it may return and who may call it.
    #
    # A tool is either declared or undeclared.
    #
    # A declared tool comes from {Otto::MCP::Core#register_mcp_tool}. Otto
    # validates its arguments against the input schema before the handler
    # runs, validates the handler's return value against the output schema
    # when there is one, and calls it only for a caller whose verified scopes
    # cover its scopes.
    #
    # An undeclared tool comes from a +TOOL+ route line or from the
    # four-argument {Otto::MCP::Registry#register_tool}. Otto advertises the
    # schema it was given, passes the arguments through unchecked and returns
    # the handler's value as text.
    class Tool
      # Letters, digits, underscore, hyphen and dot, 1 to 128 characters.
      NAME = /\A[A-Za-z0-9_.-]{1,128}\z/

      # An OAuth scope token (RFC 6749 section 3.3): printable ASCII without
      # space, double quote or backslash.
      SCOPE = /\A[\x21\x23-\x5B\x5D-\x7E]+\z/

      # At most this many argument violations are reported to the caller.
      MAX_REPORTED_VIOLATIONS = 10

      attr_reader :name, :title, :description, :input_schema, :output_schema, :scopes, :annotations, :handler

      # Build the tool a +TOOL+ route line or a positional registration
      # describes. Nothing is validated or enforced.
      #
      # @return [Otto::MCP::Tool]
      def self.undeclared(name, description, input_schema, handler)
        allocate.tap { |tool| tool.send(:initialize_undeclared, name, description, input_schema, handler) }
      end

      # @param scopes [Object] value given as +scopes:+
      # @param label [String] names the owner in the error message
      # @return [Array<String>] frozen, without duplicates
      # @raise [ArgumentError] unless every entry is an OAuth scope token
      def self.normalize_scopes(scopes, label)
        list    = scopes.is_a?(String) ? [scopes] : scopes.to_a
        invalid = list.reject { |scope| scope.is_a?(String) && scope.match?(SCOPE) }.map(&:inspect)
        raise ArgumentError, "#{label} scopes must be OAuth scope tokens, got #{invalid.join(', ')}" unless invalid.empty?

        list.uniq.map(&:freeze).freeze
      end

      # @param name [String]
      # @param handler [#call, String] takes +(arguments, env)+; a String
      #   names a class method as +"Namespace::Class.method"+
      # @param description [String] what the tool does, for the model
      # @param input_schema [Hash] JSON Schema for the arguments; its root
      #   type must be +object+
      # @param output_schema [Hash, nil] JSON Schema for the return value
      # @param scopes [Array<String>, nil] scopes a caller must have
      # @param title [String, nil] display name
      # @param annotations [Hash, nil] behavior hints passed to clients
      # @raise [ArgumentError] for an invalid name, handler, schema or scope
      # @raise [Otto::OptionalDependencyError] if json_schemer is not installed
      # rubocop:disable-next Metrics/ParameterLists -- a keyword-only definition
      def initialize(name:, handler:, description:, input_schema:,
                     output_schema: nil, scopes: nil, title: nil, annotations: nil)
        named = name.is_a?(String) && name.match?(NAME)
        raise ArgumentError, "MCP tool name #{name.inspect} must match #{NAME.inspect}" unless named

        @declared    = true
        @name        = name.dup.freeze
        @title       = title&.to_s&.freeze
        @description = text!(description, "MCP tool #{name} description")
        @handler     = handler!(handler)
        @scopes      = self.class.normalize_scopes(scopes || [], "MCP tool #{name}")
        @annotations = annotations && JSON.parse(JSON.generate(annotations), freeze: true)

        Validator.ensure_available!
        @input_schema  = Schema.input(input_schema, "MCP tool #{name} input_schema")
        @output_schema = output_schema && Schema.normalize(output_schema, "MCP tool #{name} output_schema")
        @input_check   = Schema.compile(@input_schema, "MCP tool #{name} input_schema")
        @output_check  = @output_schema && Schema.compile(@output_schema, "MCP tool #{name} output_schema")
        freeze
      end

      # @return [Boolean] true when Otto enforces this tool's schemas
      def declared?
        @declared
      end

      # @param auth [Otto::MCP::Auth::Context, nil] the verified caller
      # @return [Boolean] true when the caller may list and call this tool
      def permits?(auth)
        scopes.empty? || (!auth.nil? && auth.grants?(scopes))
      end

      # @return [Hash] the entry for this tool in a +tools/list+ result
      def listing
        return { name: name, description: description, inputSchema: input_schema } unless declared?

        {
                  name: name, title: title, description: description, inputSchema: input_schema,
          outputSchema: output_schema, annotations: annotations
        }.compact
      end

      # @param arguments [Object] the +arguments+ member of a +tools/call+
      # @return [Array<String>] one message per violation, naming the
      #   location and the rule but never the value; empty when valid
      def input_violations(arguments)
        @input_check.validate(arguments).first(MAX_REPORTED_VIOLATIONS).map { |violation| violation['error'] }
      end

      # @param value [Object] a handler's return value, as JSON types
      # @return [Array<Hash>] the keyword and schema location of each
      #   violation; empty when valid or when there is no output schema
      def output_violations(value)
        return [] unless @output_check

        @output_check.validate(value).first(MAX_REPORTED_VIOLATIONS).map do |violation|
          { keyword: violation['type'], schema_pointer: violation['schema_pointer'] }
        end
      end

      # Run the handler.
      #
      # @param arguments [Hash]
      # @param env [Hash] Rack env of the MCP request
      # @return [Object] whatever the handler returns
      def invoke(arguments, env)
        return handler.call(arguments, env) if handler.respond_to?(:call)
        raise "Invalid tool handler: #{handler}" unless handler.is_a?(String) && handler.include?('.')

        *namespace, method_name = handler.split('.')
        Otto::Security::ConstantResolver.safe_const_get(namespace.join('::')).public_send(method_name, arguments, env)
      end

      private

      def text!(value, label)
        raise ArgumentError, "#{label} must be a non-blank String" unless value.is_a?(String) && !value.strip.empty?

        value.dup.freeze
      end

      def handler!(handler)
        return handler if handler.respond_to?(:call)
        return handler.dup.freeze if handler.is_a?(String) && handler.match?(/\A[A-Z][\w:]*\.\w+[?!]?\z/)

        raise ArgumentError, "MCP tool #{name} handler must respond to #call or name a class method as 'Class.method'"
      end

      def initialize_undeclared(name, description, input_schema, handler)
        @declared     = false
        @name         = name
        @description  = description
        @input_schema = input_schema
        @handler      = handler
        @scopes       = [].freeze
        freeze
      end

      # Normalizes, checks and compiles the JSON Schemas of declared tools.
      # @api private
      module Schema
        NETWORK_REF = %r{\A[a-z][a-z0-9+.-]*://}i

        # @return [Hash] a deep-frozen, String-keyed copy whose root rejects
        #   properties it does not name, unless it says otherwise
        def self.input(schema, label)
          copy = plain(schema, label)
          raise ArgumentError, "#{label} must have type \"object\" at its root" unless copy['type'] == 'object'

          copy['additionalProperties'] = false unless copy.key?('additionalProperties')
          normalize(copy, label)
        end

        # @return [Hash] a deep-frozen, String-keyed copy
        def self.normalize(schema, label)
          copy = plain(schema, label)
          reject_unsupported!(copy, label)
          raise ArgumentError, "#{label} is not a valid JSON Schema" unless usable(label) { JSONSchemer.valid_schema?(copy) }

          JSON.parse(JSON.generate(copy), freeze: true)
        end

        # @return [JSONSchemer::Schema] compiled once, at registration
        def self.compile(schema, label)
          usable(label) { JSONSchemer.schema(schema).tap { |compiled| compiled.validate({}).first } }
        end

        # json_schemer raises its own StandardError subclasses for a dialect
        # or reference it cannot resolve. They become a registration failure.
        def self.usable(label)
          yield
        rescue StandardError => e
          raise ArgumentError, "#{label} cannot be used: #{e.class.name.split('::').last}"
        end
        private_class_method :usable

        def self.plain(schema, label)
          raise ArgumentError, "#{label} must be a Hash" unless schema.is_a?(Hash)

          JSON.parse(JSON.generate(schema))
        end
        private_class_method :plain

        # A schema that names an HTTP header for an argument obliges the
        # server to check that header against the body on every call, which
        # Otto does not do. A +$ref+ to a network address is never fetched,
        # so it could not be enforced either. Both fail the registration.
        def self.reject_unsupported!(node, label)
          case node
          when Hash
            raise ArgumentError, "#{label} uses x-mcp-header, which Otto does not support" if node.key?('x-mcp-header')

            remote = node['$ref'].is_a?(String) && node['$ref'].match?(NETWORK_REF)
            raise ArgumentError, "#{label} has a $ref to a network address, which Otto does not fetch" if remote

            node.each_value { |value| reject_unsupported!(value, label) }
          when Array
            node.each { |value| reject_unsupported!(value, label) }
          end
        end
        private_class_method :reject_unsupported!
      end
    end
  end
end
