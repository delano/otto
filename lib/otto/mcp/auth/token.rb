# lib/otto/mcp/auth/token.rb
#
# frozen_string_literal: true

require 'json'

class Otto
  module MCP
    module Auth
      # Token-based authentication for MCP protocol endpoints
      class TokenAuth
        def initialize(tokens)
          @tokens = Array(tokens).to_set
        end

        def authenticate(env)
          token = extract_token(env)
          return false unless token

          @tokens.include?(token)
        end

        private

        def extract_token(env)
          # Try Authorization header first (Bearer token)
          auth_header = env['HTTP_AUTHORIZATION']
          return auth_header[7..] if auth_header&.start_with?('Bearer ')

          # Try X-MCP-Token header
          env['HTTP_X_MCP_TOKEN']
        end
      end

      # Middleware for token authentication in MCP protocol
      class TokenMiddleware
        def initialize(app, security_config = nil)
          @app             = app
          @security_config = security_config
        end

        def call(env)
          # Only apply to MCP endpoints
          return @app.call(env) unless mcp_endpoint?(env)

          # Get auth instance from security config
          auth = @security_config&.mcp_auth
          return unauthorized_response if auth && !auth.authenticate(env)

          @app.call(env)
        end

        private

        def mcp_endpoint?(env)
          endpoint = env['otto.mcp_http_endpoint'] || '/_mcp'
          path     = env['PATH_INFO'].to_s
          path.start_with?(endpoint)
        end

        def unauthorized_response
          body = JSON.generate({
                                 jsonrpc: '2.0',
            id: nil,
            error: {
              code: -32_000,
              message: 'Unauthorized',
              data: 'Valid token required',
            },
                               })

          [401, { 'content-type' => 'application/json' }, [body]]
        end
      end
    end
  end
end
