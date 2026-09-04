# lib/otto/mcp/protocol.rb
#
# frozen_string_literal: true

require 'json'
require_relative 'registry'
require_relative 'errors'

class Otto
  module MCP
    # MCP protocol handler providing Model Context Protocol functionality.
    #
    # == JSON-RPC error code to HTTP status mapping
    #
    #   Code     Meaning                 HTTP
    #   -32700   Parse error             400
    #   -32600   Invalid Request         400
    #   -32601   Method not found        400
    #   -32602   Invalid params          400
    #   -32001   Resource not found      404
    #   -32002   Tool not found          404
    #   -32603   Internal error          500
    #   -32099..-32000  server errors    500
    #
    # Protocol-level faults (a malformed or unsupported payload against a valid
    # endpoint) are 400, including method-not-found: 404 there would conflate a
    # bad payload with "no such route", which the MCP endpoint handler already
    # returns when MCP is disabled. 404 is reserved for a well-formed request
    # naming an entity that is not registered, and 500 for handler execution
    # faults. Handler exception messages are logged, never returned: -32603
    # responses carry a fixed message.
    class Protocol
      # @see Protocol for the rationale behind this mapping.
      ERROR_STATUS_MAP = {
        -32_700 => 400, # Parse error
        -32_600 => 400, # Invalid Request
        -32_601 => 400, # Method not found
        -32_602 => 400, # Invalid params
        -32_001 => 404, # Resource not found
        -32_002 => 404, # Tool not found
        -32_603 => 500, # Internal error
      }.freeze

      # Implementation-defined server error range; anything unmapped inside it
      # is an execution fault.
      SERVER_ERROR_RANGE = (-32_099..-32_000)

      attr_reader :registry

      def initialize(otto_instance)
        @otto     = otto_instance
        @registry = Registry.new
      end

      def handle_request(env)
        request = @otto.request_class.new(env)

        unless request.post? && request.content_type&.include?('application/json')
          return error_response(nil, -32_600, 'Invalid Request', 'Only JSON-RPC POST requests supported')
        end

        begin
          body = request.body.read
          data = JSON.parse(body)
        rescue JSON::ParserError
          return error_response(nil, -32_700, 'Parse error', 'Invalid JSON')
        end

        unless valid_jsonrpc_request?(data)
          return error_response(data['id'], -32_600, 'Invalid Request', 'Missing jsonrpc, method, or id fields')
        end

        case data['method']
        when 'initialize'
          handle_initialize(data)
        when 'resources/list'
          handle_resources_list(data)
        when 'resources/read'
          handle_resources_read(data)
        when 'tools/list'
          handle_tools_list(data)
        when 'tools/call'
          handle_tools_call(data, env)
        else
          error_response(data['id'], -32_601, 'Method not found', "Unknown method: #{data['method']}")
        end
      end

      private

      def valid_jsonrpc_request?(data)
        data.is_a?(Hash) &&
          data['jsonrpc'] == '2.0' &&
          data['method'].is_a?(String) &&
          data.key?('id')
      end

      def handle_initialize(data)
        capabilities = {
          resources: {
            subscribe: false,
            listChanged: false,
          },
          tools: {},
        }

        success_response(data['id'], {
                           protocolVersion: '2024-11-05',
          capabilities: capabilities,
          serverInfo: {
            name: 'Otto MCP Server',
            version: Otto::VERSION,
          },
                         })
      end

      def handle_resources_list(data)
        resources = @registry.list_resources
        success_response(data['id'], { resources: resources })
      end

      def handle_resources_read(data)
        params = data['params'] || {}
        uri    = params['uri']

        return error_response(data['id'], -32_602, 'Invalid params', 'Missing uri parameter') unless uri

        begin
          resource = @registry.read_resource(uri)
        rescue StandardError => e
          # Detail stays in the log: handler exceptions (Errno::*, constant
          # resolution) can carry absolute paths and internals.
          Otto.logger.error "[MCP] Resource read error for #{uri}: #{e.class}: #{e.message}"
          return error_response(data['id'], -32_603, 'Internal error', 'Resource read failed')
        end

        if resource
          success_response(data['id'], resource)
        else
          error_response(data['id'], -32_001, 'Resource not found', "Resource not found: #{uri}")
        end
      end

      def handle_tools_list(data)
        tools = @registry.list_tools
        success_response(data['id'], { tools: tools })
      end

      def handle_tools_call(data, env)
        params    = data['params'] || {}
        name      = params['name']
        arguments = params['arguments'] || {}

        return error_response(data['id'], -32_602, 'Invalid params', 'Missing name parameter') unless name

        begin
          result = @registry.call_tool(name, arguments, env)
          success_response(data['id'], result)
        rescue Otto::MCP::ToolNotFoundError => e
          error_response(data['id'], -32_002, 'Tool not found', e.message)
        rescue StandardError => e
          Otto.logger.error "[MCP] Tool call error for #{name}: #{e.class}: #{e.message}"
          error_response(data['id'], -32_603, 'Internal error', 'Tool execution failed')
        end
      end

      def success_response(id, result)
        body = JSON.generate({
                               jsonrpc: '2.0',
          id: id,
          result: result,
                             })

        [200, { 'content-type' => 'application/json' }, [body]]
      end

      def error_response(id, code, message, data = nil)
        error        = { code: code, message: message }
        error[:data] = data if data

        body = JSON.generate({
                               jsonrpc: '2.0',
          id: id,
          error: error,
                             })

        # Map JSON-RPC error codes to HTTP status codes (see ERROR_STATUS_MAP).
        http_status = ERROR_STATUS_MAP[code] || (SERVER_ERROR_RANGE.cover?(code) ? 500 : 400)

        [http_status, { 'content-type' => 'application/json' }, [body]]
      end
    end
  end
end
