# lib/otto/mcp/core.rb
#
# frozen_string_literal: true

class Otto
  module MCP
    # Core MCP (Model Context Protocol) methods included in the Otto class.
    # Provides the public API for enabling and querying MCP server support.
    module Core
      # Enable MCP (Model Context Protocol) server support
      #
      # Options are normalized by Otto::MCP::Server.normalize_options under the
      # :explicit scope. That scope accepts the canonical keys below and their
      # mcp_-prefixed spellings (:mcp_endpoint, :mcp_auth_tokens, ...), as
      # String or Symbol keys, so one hash can feed both Otto.new and this
      # method.
      #
      # It is STRICT: any other key raises ArgumentError rather than being
      # ignored, so a typo such as `enable_mcp!(auth_token: 'x')` fails at boot
      # instead of quietly leaving the endpoint unauthenticated. That includes
      # the constructor-only gating keys (:mcp_enabled, :mcp_http, :mcp_stdio):
      # this method always enables the HTTP endpoint, so it cannot honour them.
      #
      # @param options [Hash] MCP configuration options
      # @option options [String] :http_endpoint HTTP endpoint path (default: '/_mcp')
      # @option options [Array<String>, String] :auth_tokens Bearer tokens required
      #   on the MCP endpoint (default: none, which logs a warning)
      # @option options [Boolean] :allow_unauthenticated Acknowledge an
      #   intentionally unauthenticated endpoint, silencing that warning (default: false)
      # @option options [Boolean] :enable_validation Enable JSON schema validation (default: true)
      # @option options [Boolean] :enable_rate_limiting Enable rate limiting (default: true)
      # @option options [Integer] :requests_per_minute MCP endpoint limit (default: 60)
      # @option options [Integer] :tools_per_minute tools/call limit (default: 20)
      # @option options [Array<String>, String] :protocol_versions MCP
      #   revisions to serve (default: '2024-11-05'; '2026-07-28' when hosted)
      # @option options [#call] :authenticator takes (token, env) and returns
      #   an Otto::MCP::Auth::Context for a token it accepts, nil otherwise
      # @option options [Boolean] :hosted Require the authenticator, resource
      #   URI and declared tools a public endpoint needs (default: false)
      # @option options [String] :resource_uri Canonical URI of this endpoint;
      #   a token must have been issued for it
      # @option options [Array<String>] :authorization_servers Issuers of the
      #   tokens this endpoint accepts
      # @option options [Array<String>] :scopes_supported Scopes named in the
      #   challenge to an unauthenticated request and in the metadata document
      # @option options [Array<String>] :allowed_origins Origins a browser
      #   may call the endpoint from
      # @option options [String] :request_state_secret Key material, at least
      #   32 bytes, for the requestState of input requests
      # @option options [Hash] :server_info name and version reported to clients
      # @option options [String] :instructions Guidance for the model, sent
      #   in server/discover
      # @option options [Integer] :cache_ttl_ms How long clients may reuse
      #   list and discover results (default: 0)
      # @example
      #   otto.enable_mcp!(http_endpoint: '/api/mcp', auth_tokens: ['secret'])
      def enable_mcp!(options = {})
        ensure_not_frozen!
        @mcp_server ||= Otto::MCP::Server.new(self)

        @mcp_server.enable!(Otto::MCP::Server.normalize_options(options))
        Otto.logger.info '[MCP] Enabled MCP server' if Otto.debug
      end

      # Check if MCP is enabled
      # @return [Boolean]
      def mcp_enabled?
        @mcp_server&.enabled?
      end

      # Register a tool whose arguments, return value and callers Otto checks
      # on every call. Must be called after MCP is enabled and before the
      # first request.
      #
      # @param name [String] letters, digits, underscore, hyphen and dot
      # @param handler [#call, String, nil] takes +(arguments, env)+ and
      #   returns the result; the block when nil. A String names a class
      #   method as +"Namespace::Class.method"+.
      # @param definition [Hash] +description:+ and +input_schema:+, and
      #   optionally +output_schema:+, +scopes:+, +title:+ and +annotations:+
      #   (see Otto::MCP::Tool#initialize)
      # @return [Otto::MCP::Tool]
      # @raise [FrozenError] after the first request
      # @raise [ArgumentError] if MCP is not enabled or the definition is
      #   refused (see Otto::MCP::Server#define_tool)
      # @example
      #   otto.register_mcp_tool('get_delivery_status',
      #     description: 'Report where a handoff stands.',
      #     input_schema: { type: 'object', properties: { operation_id: { type: 'string' } },
      #                     required: ['operation_id'] },
      #     output_schema: { type: 'object', properties: { state: { type: 'string' } },
      #                      required: ['state'], additionalProperties: false },
      #     scopes: ['handoff:read'],
      #   ) do |arguments, env|
      #     { state: Handoff.state_for(arguments['operation_id'], env['otto.mcp.auth']) }
      #   end
      def register_mcp_tool(name, handler = nil, **definition, &)
        ensure_not_frozen!
        mcp_server_for_registration.define_tool(name, handler, **definition, &)
      end

      # Register a resource with the scopes a caller needs to list and read
      # it. Must be called after MCP is enabled and before the first request.
      #
      # @param uri [String]
      # @param handler [#call, nil] takes no argument or the Rack env and
      #   returns the text; the block when nil
      # @param definition [Hash] +description:+, and optionally +name:+,
      #   +mime_type:+ and +scopes:+
      # @return [void]
      # @raise [FrozenError] after the first request
      # @raise [ArgumentError] if MCP is not enabled or the definition is
      #   refused (see Otto::MCP::Server#define_resource)
      def register_mcp_resource(uri, handler = nil, **definition, &)
        ensure_not_frozen!
        mcp_server_for_registration.define_resource(uri, handler, **definition, &)
      end

      private

      def mcp_server_for_registration
        return @mcp_server if mcp_enabled?

        raise ArgumentError, 'MCP is not enabled. Call enable_mcp! or pass mcp_enabled: true to Otto.new first.'
      end
    end
  end
end
