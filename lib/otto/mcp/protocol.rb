# lib/otto/mcp/protocol.rb
#
# frozen_string_literal: true

require 'json'
require 'securerandom'

require_relative 'auth/bearer'
require_relative 'call'
require_relative 'errors'
require_relative 'json_body'
require_relative 'registry'
require_relative 'settings'

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
    #
    # == Revisions
    #
    # The table above is the 2024-11-05 behavior, which this class implements
    # and which is all an endpoint serves unless it is enabled with other
    # +protocol_versions+. Requests under 2026-07-28 are handled by
    # {Otto::MCP::Protocol::Modern}. An endpoint that serves both picks per
    # request: a request that declares a 2026-07-28 or unknown version, in the
    # MCP-Protocol-Version header or in its +_meta+, goes to Modern, and a
    # request that declares nothing is served as 2024-11-05.
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

      VERSION_HEADER = 'HTTP_MCP_PROTOCOL_VERSION'
      META_VERSION   = 'io.modelcontextprotocol/protocolVersion'
      AUTH_ENV_KEY    = 'otto.mcp.auth'
      VOUCHER_ENV_KEY = 'otto.mcp.auth.voucher'
      CALL_ENV_KEY    = 'otto.mcp.call'

      attr_reader :registry, :settings

      def initialize(otto_instance, settings = Settings.legacy)
        @otto     = otto_instance
        @registry = Registry.new
        @settings = settings
      end

      # @param settings [Otto::MCP::Settings]
      # @api private
      def configure(settings)
        @settings = settings
      end

      def handle_request(env)
        # Only this endpoint's own authenticator names the caller. A context
        # that it did not vouch for on this request is discarded, whether an
        # outer application left it in env or the request reached this
        # handler without passing the authentication middleware.
        env.delete(AUTH_ENV_KEY) unless @settings.auth && env[VOUCHER_ENV_KEY].equal?(@settings.auth)

        request = @otto.request_class.new(env)

        unless request.post? && request.content_type&.include?('application/json')
          return error_response(nil, -32_600, 'Invalid Request', 'Only JSON-RPC POST requests supported')
        end

        begin
          data = JSONBody.parse(request.body.read)
        rescue JSON::ParserError
          return error_response(nil, -32_700, 'Parse error', 'Invalid JSON')
        end

        return Modern.new(self).call(data, env) if modern_request?(data, env)

        handle_legacy_request(data, env)
      end

      # The verified caller of this request, if the endpoint has an
      # authenticator and it accepted the request.
      #
      # @param env [Hash] Rack env
      # @return [Otto::MCP::Auth::Context, nil]
      # @api private
      def caller_in(env)
        auth = env[AUTH_ENV_KEY]
        auth if auth.is_a?(Otto::MCP::Auth::Context)
      end

      # HTTP 403 with an insufficient_scope challenge naming every scope the
      # tool or resource requires, so a client can ask for them in one step.
      #
      # @param id [String, Integer, nil] JSON-RPC id of the request
      # @param error [Otto::MCP::InsufficientScopeError]
      # @param env [Hash] Rack env
      # @param target [Hash] the tool or resource that was refused
      # @return [Array] Rack response
      # @api private
      def insufficient_scope_response(id, error, env, target)
        Otto.structured_log(:warn, 'MCP call refused: insufficient scope',
          Otto::LoggingHelpers.request_context(env).merge(target).merge(client_id: caller_in(env)&.client_id))

        scopes    = error.required_scopes
        challenge = if @settings.auth
                      @settings.auth.challenge(error: 'insufficient_scope', scopes: scopes)
                    else
                      Auth::Challenge.bearer(error: 'insufficient_scope', scopes: scopes)
                    end
        body      = { jsonrpc: '2.0', id: id, error: { code: FORBIDDEN, message: 'Forbidden', data: { requiredScopes: scopes } } }

        [403, { 'content-type' => 'application/json', 'www-authenticate' => challenge }, [JSON.generate(body.compact)]]
      end

      # Log a handler failure without the exception's message, which can contain
      # anything the handler touched. The log entry and the backtrace share an
      # error_id, and the caller can be given the same id.
      #
      # @param event [String] log message
      # @param env [Hash] Rack env
      # @param error [StandardError]
      # @param details [Hash] code and the tool or resource involved
      # @return [String] the error_id
      # @api private
      def log_failure(event, env, error, details)
        error_id = SecureRandom.hex(8)
        details  = details.merge(violations: error.violations) if error.is_a?(OutputValidationError)
        context  = Otto::LoggingHelpers.request_context(env).merge(details)
                                       .merge(error_class: error.class.name, error_id: error_id)

        Otto.structured_log(:error, event, context)
        Otto::LoggingHelpers.log_backtrace(error, context)
        error_id
      end

      private

      # An endpoint that serves one era sends everything to it. One that
      # serves both goes by what the request declares. A version in _meta is
      # something only a 2026-07-28 request has, so it decides, and that
      # handler then holds the header to it. Without one, the header decides.
      def modern_request?(data, env)
        return false unless @settings.modern?
        return true unless @settings.legacy?

        params = data['params'] if data.is_a?(Hash)
        meta   = params['_meta'] if params.is_a?(Hash)
        return true if meta.is_a?(Hash) && meta.key?(META_VERSION)

        header = env[VERSION_HEADER]
        !header.nil? && !@settings.legacy_versions.include?(header)
      end

      def handle_legacy_request(data, env)
        unless valid_jsonrpc_request?(data)
          id = data['id'] if data.is_a?(Hash)
          return error_response(id, -32_600, 'Invalid Request', 'Missing jsonrpc, method, or id fields')
        end

        # The method handlers read params as an object.
        unless data['params'].nil? || data['params'].is_a?(Hash)
          return error_response(data['id'], -32_602, 'Invalid params', 'params must be an object')
        end

        case data['method']
        when 'initialize'
          handle_initialize(data)
        when 'resources/list'
          handle_resources_list(data, env)
        when 'resources/read'
          handle_resources_read(data, env)
        when 'tools/list'
          handle_tools_list(data, env)
        when 'tools/call'
          handle_tools_call(data, env)
        else
          error_response(data['id'], -32_601, 'Method not found', "Unknown method: #{data['method']}")
        end
      end

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
            name: @settings.server_info['name'],
            version: @settings.server_info['version'],
          },
                         })
      end

      def handle_resources_list(data, env)
        resources = @registry.list_resources(caller_in(env))
        success_response(data['id'], { resources: resources })
      end

      def handle_resources_read(data, env)
        params = data['params'] || {}
        uri    = params['uri']

        return error_response(data['id'], -32_602, 'Invalid params', 'Missing uri parameter') unless uri

        begin
          env[CALL_ENV_KEY] = Call.new(auth: caller_in(env), protocol_version: '2024-11-05')
          resource          = @registry.read_resource(uri, env)
        rescue InsufficientScopeError => e
          return insufficient_scope_response(data['id'], e, env, resource: uri)
        rescue StandardError => e
          log_failure('MCP resource read failed', env, e, code: 'resource_failed', resource: uri)
          return error_response(data['id'], -32_603, 'Internal error', 'Resource read failed')
        end

        if resource
          success_response(data['id'], resource)
        else
          error_response(data['id'], -32_001, 'Resource not found', "Resource not found: #{uri}")
        end
      end

      def handle_tools_list(data, env)
        tools = @registry.list_tools(caller_in(env))
        success_response(data['id'], { tools: tools })
      end

      def handle_tools_call(data, env)
        params    = data['params'] || {}
        name      = params['name']
        arguments = params['arguments'] || {}

        return error_response(data['id'], -32_602, 'Invalid params', 'Missing name parameter') unless name

        begin
          env[CALL_ENV_KEY] = Call.new(auth: caller_in(env), protocol_version: '2024-11-05')
          result            = @registry.call_tool(name, arguments, env)
          result            = INPUT_REQUEST_UNSUPPORTED if result.is_a?(InputRequired)
          success_response(data['id'], result)
        rescue Otto::MCP::ToolNotFoundError => e
          error_response(data['id'], -32_002, 'Tool not found', e.message)
        rescue InsufficientScopeError => e
          insufficient_scope_response(data['id'], e, env, tool: name)
        rescue StandardError => e
          code = e.is_a?(OutputValidationError) ? 'tool_output_invalid' : 'tool_failed'
          log_failure('MCP tool call failed', env, e, code: code, tool: name)
          error_response(data['id'], -32_603, 'Internal error', 'Tool execution failed')
        end
      end

      # 2024-11-05 has no way to ask the client for input in the middle of a
      # call, so a tool that needs it reports that it cannot run here.
      INPUT_REQUEST_UNSUPPORTED = {
        content: [{ type: 'text', text: 'This tool needs a client that supports MCP 2026-07-28.' }],
        isError: true,
      }.freeze
      private_constant :INPUT_REQUEST_UNSUPPORTED

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

        response = { jsonrpc: '2.0', id: id, error: error }
        # 2026-07-28 has no null id. An endpoint that serves only that
        # revision leaves the member out when the id could not be read.
        response.delete(:id) if id.nil? && !@settings.legacy?

        # Map JSON-RPC error codes to HTTP status codes (see ERROR_STATUS_MAP).
        http_status = ERROR_STATUS_MAP[code] || (SERVER_ERROR_RANGE.cover?(code) ? 500 : 400)

        [http_status, { 'content-type' => 'application/json' }, [JSON.generate(response)]]
      end
    end
  end
end

require_relative 'protocol/modern'
