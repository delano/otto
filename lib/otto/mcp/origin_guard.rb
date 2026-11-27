# lib/otto/mcp/origin_guard.rb
#
# frozen_string_literal: true

require 'json'

require_relative 'endpoint'
require_relative 'errors'

class Otto
  module MCP
    # Rejects a request to the MCP endpoint whose +Origin+ header is not on
    # the endpoint's allowlist.
    #
    # A browser attaches +Origin+ to cross-site requests, and a page that has
    # rebound its own hostname to this server's address still reports its own
    # origin. Comparing +Origin+ with the request's +Host+ therefore proves
    # nothing; only a configured list does. A request with no +Origin+ header
    # is not a browser cross-site request and passes.
    #
    # The guard matches the exact endpoint path, like the other MCP
    # middleware, and runs before authentication and request parsing.
    class OriginGuard
      # +scheme://host+ with an optional port, and nothing after it.
      ORIGIN = %r{\A[a-z][a-z0-9+.-]*://[^/?#\s]+\z}i

      # @param origin [String]
      # @return [String] the origin in the form it is compared in
      def self.normalize(origin)
        origin.to_s.strip.downcase
      end

      # @param app [#call]
      # @param endpoint [String] the MCP endpoint path
      # @param allowed_origins [Array<String>] normalized origins
      def initialize(app, endpoint, allowed_origins = [])
        @app      = app
        @endpoint = endpoint
        @allowed  = allowed_origins.to_set.freeze
      end

      def call(env)
        return @app.call(env) unless Otto::MCP.endpoint_path?(env['PATH_INFO'], @endpoint)

        origin = env['HTTP_ORIGIN']
        return @app.call(env) if origin.nil? || @allowed.include?(self.class.normalize(origin))

        Otto.structured_log(:warn, 'MCP request origin rejected', Otto::LoggingHelpers.request_context(env))
        error = { code: Otto::MCP::FORBIDDEN, message: 'Forbidden', data: 'Origin not allowed' }
        [403, { 'content-type' => 'application/json' }, [JSON.generate({ jsonrpc: '2.0', error: error })]]
      end
    end
  end
end
