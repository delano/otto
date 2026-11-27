# lib/otto/mcp/protocol/modern.rb
#
# frozen_string_literal: true

require 'digest'
require 'json'

class Otto
  module MCP
    class Protocol
      # Serves one request under MCP revision 2026-07-28.
      #
      # That revision has no +initialize+ handshake and no session. Every
      # request states its protocol version and the client's capabilities in
      # +params._meta+, and repeats the version, the method and the tool name
      # or resource URI in HTTP headers. This handler refuses a request whose
      # headers and body disagree before it does anything else with it.
      #
      # == JSON-RPC error code to HTTP status mapping
      #
      #   Code     Meaning                            HTTP
      #   -32700   Parse error                        400
      #   -32600   Invalid Request                    400
      #   -32601   Method not found                   404
      #   -32602   Invalid params, unknown tool,
      #            unknown resource                   400
      #   -32603   Internal error                     500
      #   -32020   Header mismatch                    400
      #   -32021   Missing required client capability 400
      #   -32022   Unsupported protocol version       400
      class Modern
        META_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities'
        META_CLIENT_INFO  = 'io.modelcontextprotocol/clientInfo'
        META_SERVER_INFO  = 'io.modelcontextprotocol/serverInfo'

        HEADER_MISMATCH       = -32_020
        MISSING_CAPABILITY    = -32_021
        UNSUPPORTED_VERSION   = -32_022
        NAMED_METHODS         = { 'tools/call' => 'name', 'resources/read' => 'uri' }.freeze
        ENCODED_HEADER        = %r{\A=\?base64\?([A-Za-z0-9+/]*={0,2})\?=\z}
        HTTP_STATUS           = { -32_601 => 404, -32_603 => 500 }.freeze
        MAX_ECHOED_NAME_CHARS = 128

        # Carries a finished Rack response out of a validation step.
        class Halt < StandardError
          attr_reader :response

          def initialize(response)
            @response = response
            super('MCP request refused')
          end
        end

        # @param protocol [Otto::MCP::Protocol]
        def initialize(protocol)
          @protocol = protocol
          @registry = protocol.registry
          @settings = protocol.settings
        end

        # @param data [Object] the parsed request body
        # @param env [Hash] Rack env
        # @return [Array] Rack response
        def call(data, env)
          @id = nil
          halt!(-32_600, 'Invalid Request', 'A request is a JSON object with jsonrpc, method and id') unless request?(data)

          @id    = data['id']
          params = data.fetch('params', {})
          halt!(-32_602, 'Invalid params', 'params must be an object') unless params.is_a?(Hash)

          meta = check_metadata!(data['method'], params, env)
          return unauthorized(env) if @settings.hosted && @protocol.caller_in(env).nil?

          dispatch(data['method'], params, meta, env)
        rescue Halt => e
          e.response
        end

        private

        def request?(data)
          data.is_a?(Hash) && data['jsonrpc'] == '2.0' && data['method'].is_a?(String) &&
            (data['id'].is_a?(String) || data['id'].is_a?(Integer))
        end

        # Checks the version and method the request declares, in its headers
        # and in its body, and returns the request's _meta.
        def check_metadata!(method, params, env)
          meta    = params['_meta'].is_a?(Hash) ? params['_meta'] : {}
          version = env[Protocol::VERSION_HEADER]
          mismatch!("MCP-Protocol-Version header is required. Supported versions: #{supported.join(', ')}") if version.nil?
          mismatch!('Mcp-Method header does not match the request method') unless env['HTTP_MCP_METHOD'] == method

          declared = meta[Protocol::META_VERSION]
          halt!(-32_602, 'Invalid params', "Missing _meta #{Protocol::META_VERSION}") unless declared.is_a?(String)
          mismatch!('MCP-Protocol-Version header does not match the version in _meta') unless declared == version

          served = @settings.modern_versions.include?(version)
          halt!(UNSUPPORTED_VERSION, 'Unsupported protocol version', { supported: supported, requested: version[0, 32] }) unless served

          halt!(-32_602, 'Invalid params', "Missing _meta #{META_CAPABILITIES}") unless meta[META_CAPABILITIES].is_a?(Hash)

          check_name_header!(params[NAMED_METHODS[method]], env) if NAMED_METHODS.key?(method)
          meta
        end

        # The Mcp-Name header repeats the tool name or resource URI. A value
        # that is not plain ASCII arrives Base64-encoded between =?base64?
        # and ?=. A missing body value is left for the method to report.
        def check_name_header!(expected, env)
          return unless expected.is_a?(String)

          header = env['HTTP_MCP_NAME']
          mismatch!('Mcp-Name header is required for this method') if header.nil?

          encoded = header[ENCODED_HEADER, 1]
          actual  = encoded ? encoded.unpack1('m') : header
          mismatch!('Mcp-Name header does not match the request body') unless actual.b == expected.b
        end

        def dispatch(method, params, meta, env)
          case method
          when 'server/discover' then discover
          when 'tools/list' then list(params) { { tools: @registry.list_tools(@protocol.caller_in(env)) } }
          when 'resources/list' then list(params) { { resources: @registry.list_resources(@protocol.caller_in(env)) } }
          when 'tools/call' then call_tool(params, meta, env)
          when 'resources/read' then read_resource(params, meta, env)
          else
            # initialize is how a 2025-11-25 or earlier client opens. It has
            # no way to learn what to do next except from this message.
            detail = method == 'initialize' ? "Supported versions: #{supported.join(', ')}" : 'Unknown method'
            error(-32_601, 'Method not found', detail)
          end
        end

        def discover
          result = { supportedVersions: supported, capabilities: { tools: {}, resources: {} } }
          result[:instructions] = @settings.instructions if @settings.instructions
          complete(result.merge(ttlMs: @settings.cache_ttl_ms, cacheScope: 'public'))
        end

        # Everything is returned in one page, so any cursor is one this
        # endpoint never issued. A list that depends on the caller's scopes
        # must not be shared between callers.
        def list(params)
          halt!(-32_602, 'Invalid params', 'Unknown cursor') if params.key?('cursor')

          complete(yield.merge(ttlMs: @settings.cache_ttl_ms, cacheScope: @registry.scoped? ? 'private' : 'public'))
        end

        def call_tool(params, meta, env)
          name      = params['name']
          arguments = params.fetch('arguments', {})
          halt!(-32_602, 'Invalid params', 'Missing name parameter') unless name.is_a?(String)
          halt!(-32_602, 'Invalid params', 'arguments must be an object') unless arguments.is_a?(Hash)

          binding = binding_for(env, 'tools/call', name, arguments)
          invocation = invocation(params, meta, env, binding)
          env[Protocol::CALL_ENV_KEY] = invocation

          result = @registry.call_tool(name, arguments, env)
          return input_required(result, invocation, binding) if result.is_a?(InputRequired)

          complete(result)
        rescue ToolNotFoundError
          error(-32_602, "Unknown tool: #{name[0, MAX_ECHOED_NAME_CHARS]}")
        rescue InsufficientScopeError => e
          @protocol.insufficient_scope_response(@id, e, env, tool: name)
        rescue Halt
          raise
        rescue StandardError => e
          internal_error('MCP tool call failed', env, e, code: failure_code(e), tool: name)
        end

        def read_resource(params, meta, env)
          uri = params['uri']
          halt!(-32_602, 'Invalid params', 'Missing uri parameter') unless uri.is_a?(String)

          env[Protocol::CALL_ENV_KEY] = invocation(params, meta, env, nil)
          resource = @registry.read_resource(uri, env)
          return error(-32_602, 'Resource not found', { uri: uri[0, MAX_ECHOED_NAME_CHARS] }) unless resource

          # A handler is given the request and may answer differently for
          # each caller, so what it returns is never shared or kept.
          complete(resource.merge(ttlMs: 0, cacheScope: 'private'))
        rescue InsufficientScopeError => e
          @protocol.insufficient_scope_response(@id, e, env, resource: uri)
        rescue Halt
          raise
        rescue StandardError => e
          internal_error('MCP resource read failed', env, e, code: 'resource_failed', resource: uri)
        end

        # The handler's view of this call. requestState is opened here, with
        # the caller and the call it must have been issued for, and a value
        # that does not open fails the request.
        def invocation(params, meta, env, binding)
          responses = params.fetch('inputResponses', {})
          halt!(-32_602, 'Invalid params', 'inputResponses must be an object') unless responses.is_a?(Hash)

          Call.new(
            auth: @protocol.caller_in(env),
            protocol_version: meta[Protocol::META_VERSION],
            client_capabilities: meta[META_CAPABILITIES],
            client_info: meta[META_CLIENT_INFO],
            input_responses: responses,
            state: open_state(params['requestState'], binding)
          )
        end

        def open_state(sealed, binding)
          return nil if sealed.nil?

          raise InvalidRequestStateError, 'unbound' if binding.nil? || @settings.request_state.nil?

          @settings.request_state.open(sealed, binding: binding)
        rescue InvalidRequestStateError
          halt!(-32_602, 'Invalid params', 'requestState was not issued for this request')
        end

        # Ties a requestState to who is calling and what they are calling.
        # Without a verified caller there is nothing to tie it to.
        def binding_for(env, method, name, arguments)
          auth = @protocol.caller_in(env)
          return nil unless auth

          JSON.generate([auth.principal_key, method, name, Digest::SHA256.hexdigest(JSON.generate(canonical(arguments)))])
        end

        def canonical(value)
          case value
          when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key.to_s, canonical(item)] }
          when Array then value.map { |item| canonical(item) }
          else value
          end
        end

        # Answer a call with the handler's request for input. The request
        # goes only to a verified caller whose client said it can open a URL.
        def input_required(required, invocation, binding)
          raise InputRequestError, 'An input request needs a verified caller' if binding.nil? || @settings.request_state.nil?

          unless invocation.url_elicitation?
            halt!(MISSING_CAPABILITY, 'Server requires the elicitation capability with url mode for this request',
              { requiredCapabilities: required.required_capabilities })
          end

          state = @settings.request_state.seal(required.state, binding: binding, ttl: required.ttl)
          respond(200, result: with_server_info(resultType: 'input_required', inputRequests: required.requests,
                                                requestState: state))
        end

        def failure_code(error)
          case error
          when OutputValidationError then 'tool_output_invalid'
          when InputRequestError then 'input_request_unbound'
          else 'tool_failed'
          end
        end

        def internal_error(event, env, exception, details)
          error_id = @protocol.log_failure(event, env, exception, details)
          error(-32_603, 'Internal error', { error_id: error_id })
        end

        def unauthorized(env)
          headers = { 'www-authenticate' => @settings.auth.challenge(env) }
          respond(401, headers, error: { code: UNAUTHORIZED, message: 'Unauthorized', data: 'Valid token required' })
        end

        def supported
          @settings.protocol_versions
        end

        def complete(result)
          respond(200, result: with_server_info(result.merge(resultType: 'complete')))
        end

        def with_server_info(result)
          result.merge(_meta: { META_SERVER_INFO => @settings.server_info })
        end

        def mismatch!(message)
          halt!(HEADER_MISMATCH, "Header mismatch: #{message}")
        end

        def halt!(code, message, data = nil)
          raise Halt, error(code, message, data)
        end

        def error(code, message, data = nil)
          respond(HTTP_STATUS.fetch(code, 400), error: { code: code, message: message, data: data }.compact)
        end

        def respond(status, headers = {}, **member)
          body = { jsonrpc: '2.0', id: @id }.compact.merge(member)
          [status, { 'content-type' => 'application/json' }.merge(headers), [JSON.generate(body)]]
        end
      end
    end
  end
end
