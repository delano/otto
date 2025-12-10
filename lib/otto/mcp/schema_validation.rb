# lib/otto/mcp/schema_validation.rb
#
# frozen_string_literal: true

require 'json'

begin
  require 'json_schemer'
rescue LoadError
  # json_schemer is optional - graceful fallback
end

class Otto
  module MCP
    class ValidationError < Otto::BadRequestError; end

    # JSON Schema validator for MCP protocol requests
    class Validator
      def initialize
        @schemas                = {}
        @json_schemer_available = defined?(JSONSchemer)
      end

      def validate_request(data)
        return true unless @json_schemer_available

        schema            = mcp_request_schema
        validation_errors = schema.validate(data).to_a

        unless validation_errors.empty?
          error_messages = validation_errors.map { |error| error['details'] || error['error'] || error.to_s }.join(', ')
          raise ValidationError, "Invalid MCP request: #{error_messages}"
        end

        true
      end

      def validate_tool_arguments(tool_name, arguments, schema)
        return true unless @json_schemer_available && schema

        schemer           = JSONSchemer.schema(schema)
        validation_errors = schemer.validate(arguments).to_a

        unless validation_errors.empty?
          error_messages = validation_errors.map { |error| error['details'] || error['error'] || error.to_s }.join(', ')
          raise ValidationError, "Invalid arguments for tool #{tool_name}: #{error_messages}"
        end

        true
      end

      private

      def mcp_request_schema
        @schemas[:mcp_request] ||= JSONSchemer.schema({
                                                        type: 'object',
          required: %w[jsonrpc method id],
          properties: {
            jsonrpc: { const: '2.0' },
            method: { type: 'string' },
            id: {},
            params: { type: 'object' },
          },
          additionalProperties: false,
                                                      })
      end
    end

    # Middleware for validating MCP protocol requests using JSON schema
    # Validates JSON-RPC 2.0 structure and tool argument schemas
    class SchemaValidationMiddleware
      def initialize(app, _security_config = nil)
        @app       = app
        @validator = Validator.new
      end

      def call(env)
        # Only validate MCP endpoints
        return @app.call(env) unless mcp_endpoint?(env)

        request = Otto::Request.new(env)

        if request.post? && request.content_type&.include?('application/json')
          begin
            body = request.body.read
            data = JSON.parse(body)
            @validator.validate_request(data)

            # Reset body for downstream middleware
            request.body.rewind if request.body.respond_to?(:rewind)
          rescue JSON::ParserError => e
            return validation_error_response(nil, "Invalid JSON: #{e.message}")
          rescue ValidationError => e
            return validation_error_response(data&.dig('id'), e.message)
          end
        end

        @app.call(env)
      end

      private

      def mcp_endpoint?(env)
        endpoint = env['otto.mcp_http_endpoint'] || '/_mcp'
        path     = env['PATH_INFO'].to_s
        path.start_with?(endpoint)
      end

      def validation_error_response(id, message)
        body = JSON.generate({
                               jsonrpc: '2.0',
          id: id,
          error: {
            code: -32_600,
            message: 'Invalid Request',
            data: message,
          },
                             })

        [400, { 'content-type' => 'application/json' }, [body]]
      end
    end
  end
end
