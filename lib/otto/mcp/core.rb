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
    end
  end
end
