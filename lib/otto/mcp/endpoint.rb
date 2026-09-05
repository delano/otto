# lib/otto/mcp/endpoint.rb
#
# frozen_string_literal: true

require_relative '../utils'

class Otto
  # Model Context Protocol support.
  module MCP
    # Whether +path+ is the MCP endpoint +endpoint+: the one request the router
    # dispatches to the MCP handler, and nothing else.
    #
    # The MCP route is a literal route. The router normalizes PATH_INFO with
    # Otto::Utils.normalize_path and looks it up by exact equality, so it never
    # dispatches a sibling path to the MCP handler. The throttles, the throttled
    # responder, the log subscriber, the token middleware and the schema
    # validator all used to classify by prefix (start_with?) instead: with MCP
    # mounted at /a, every /admin request was counted by 'mcp_requests:/a' and
    # could be answered with an MCP JSON-RPC 429, or a 401, for a path the MCP
    # handler can never receive; with MCP at / that was every route in the app.
    #
    # Both sides go through the router's normalize_path, as LocalhostGuard does
    # for the Caddy endpoint, so a trailing slash or percent-encoding on either
    # side cannot make these guards and the router disagree about a request.
    #
    # Callers must pass PATH_INFO (Rack::Request#path_info), never
    # Rack::Request#path, which prepends SCRIPT_NAME. The router matches on
    # PATH_INFO alone, so when the host app mounts Otto under a prefix
    # (`map '/api' { run otto }`) the endpoint /_mcp is dispatched for
    # PATH_INFO=/_mcp while #path reads /api/_mcp and never matches.
    #
    # @param path [String, nil] raw PATH_INFO of the request
    # @param endpoint [String, nil] configured MCP endpoint
    # @return [Boolean]
    def self.endpoint_path?(path, endpoint)
      return false if endpoint.nil?

      Otto::Utils.normalize_path(path) == Otto::Utils.normalize_path(endpoint)
    end
  end
end
