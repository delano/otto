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
      # @param options [Hash] MCP configuration options
      # @option options [Boolean] :http Enable HTTP endpoint (default: true)
      # @option options [Boolean] :stdio Enable STDIO communication (default: false)
      # @option options [String] :endpoint HTTP endpoint path (default: '/_mcp')
      # @example
      #   otto.enable_mcp!(http: true, endpoint: '/api/mcp')
      def enable_mcp!(options = {})
        ensure_not_frozen!
        @mcp_server ||= Otto::MCP::Server.new(self)

        @mcp_server.enable!(options)
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
