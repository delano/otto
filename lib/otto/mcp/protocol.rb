# lib/otto/mcp/protocol.rb

# lib/otto/mcp/protocol.rb

require 'json'
require_relative 'registry'

class Otto
  module MCP
    # MCP protocol handler providing Model Context Protocol functionality
    class Protocol
      attr_reader :registry

      def initialize(otto_instance)
        @otto     = otto_instance
        @registry = Registry.new
      end

      def handle_request(env)
        request = Rack::Request.new(env)

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

        resource = @registry.read_resource(uri)
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
        rescue StandardError => e
          Otto.logger.error "[MCP] Tool call error: #{e.message}"
          error_response(data['id'], -32_603, 'Internal error', e.message)
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

        # Map JSON-RPC error codes to appropriate HTTP status codes
        http_status = case code
                      when -32_700..-32_600 # Parse error, Invalid Request, Method not found
                        400
                      when -32_603, -32_000..-32_099 # Internal error and all server error range (-32000..-32099)
                        500
                      when -32_001         # Resource not found
                        404
                      when -32_002         # Tool not found
                        404
                      when -32_601         # Method not found
                        404
                      when -32_602         # Invalid params
                        400
                      else
                        # Default client error for unknown non-server codes; treat server-range as 500
                        (-32_099..-32_000).cover?(code) ? 500 : 400
                      end

        [http_status, { 'content-type' => 'application/json' }, [body]]
      end
    end
  end
end
