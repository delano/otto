require 'json'
require 'set'

class Otto
  module MCP
    module Auth
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
          if auth_header&.start_with?('Bearer ')
            return auth_header[7..-1]
          end

          # Try X-MCP-Token header
          env['HTTP_X_MCP_TOKEN']
        end
      end

      class TokenMiddleware
        def initialize(app, security_config = nil)
          @app = app
          @security_config = security_config
        end

        def call(env)
          # Only apply to MCP endpoints
          return @app.call(env) unless mcp_endpoint?(env)

          # Get auth instance from security config
          auth = @security_config&.mcp_auth
          if auth && !auth.authenticate(env)
            return unauthorized_response
          end

          @app.call(env)
        end

        private

        def mcp_endpoint?(env)
          env['PATH_INFO']&.start_with?('/_mcp')
        end

        def unauthorized_response
          body = JSON.generate({
            jsonrpc: '2.0',
            id: nil,
            error: {
              code: -32000,
              message: 'Unauthorized',
              data: 'Valid token required'
            }
          })

          [401, {'content-type' => 'application/json'}, [body]]
        end
      end
    end
  end
end
