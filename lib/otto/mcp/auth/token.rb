# lib/otto/mcp/auth/token.rb
#
# frozen_string_literal: true

require 'json'
require 'rack/utils'

require_relative '../endpoint'
require_relative '../errors'
require_relative 'context'
require_relative '../../core/redacted_inspect'

class Otto
  module MCP
    module Auth
      # Token-based authentication for MCP protocol endpoints
      class TokenAuth
        include Otto::Core::RedactedInspect

        def initialize(tokens)
          # A frozen SecretSet of frozen SecretStrings. Otto::Core::Freezable
          # only shallow-freezes a TokenAuth, and nothing here mutates the
          # tokens after construction, so they are frozen now.
          @tokens = Otto::Core::RedactedInspect.secret(Array(tokens).to_set).freeze
        end

        def authenticate(env)
          token = extract_token(env)
          return false unless token

          valid_token?(token)
        end

        private

        # #inspect shows the tokens as [REDACTED] with their count.
        def redacted_inspect_value(ivar, value)
          ivar == :@tokens ? redacted_placeholder(value) : super
        end

        def valid_token?(candidate)
          # Constant-time membership: compare against every configured token without
          # short-circuiting on the first match, so neither match position nor
          # membership leaks via timing. Rack::Utils.secure_compare itself is
          # constant-time for equal-length strings.
          @tokens.reduce(false) do |matched, token|
            Rack::Utils.secure_compare(token, candidate) || matched
          end
        end

        def extract_token(env)
          # Try Authorization header first (Bearer token)
          auth_header = env['HTTP_AUTHORIZATION']
          return auth_header[7..] if auth_header&.start_with?('Bearer ')

          # Try X-MCP-Token header
          env['HTTP_X_MCP_TOKEN']
        end
      end

      # Middleware that authenticates requests to the MCP endpoint.
      #
      # It serves both authenticators: {TokenAuth}, whose #authenticate
      # answers true or false for a static token, and {BearerAuth}, whose
      # #authenticate returns the verified caller as an
      # {Otto::MCP::Auth::Context}. A Context is stored in
      # +env['otto.mcp.auth']+ for the protocol handler and for tool and
      # resource handlers. Any value already under that key is removed first,
      # so an outer application cannot supply the caller.
      class TokenMiddleware
        AUTH_ENV_KEY = 'otto.mcp.auth'

        def initialize(app, security_config = nil)
          @app             = app
          @security_config = security_config
        end

        def call(env)
          # Only apply to MCP endpoints
          return @app.call(env) unless mcp_endpoint?(env)

          env.delete(AUTH_ENV_KEY)

          # Fail closed: this middleware is only mounted when MCP auth was
          # requested, so a missing authenticator is a misconfiguration, not a
          # licence to serve the endpoint unauthenticated (issue #258).
          auth    = @security_config&.mcp_auth
          outcome = auth&.authenticate(env)
          return unauthorized_response(env, auth) unless outcome

          env[AUTH_ENV_KEY] = outcome if outcome.is_a?(Otto::MCP::Auth::Context)

          @app.call(env)
        end

        private

        # Exact endpoint only, normalized as the router normalizes it. A prefix
        # match would answer 401 for sibling paths (/admin beside /a) that the
        # MCP handler never receives.
        def mcp_endpoint?(env)
          endpoint = env['otto.mcp_http_endpoint'] || '/_mcp'
          Otto::MCP.endpoint_path?(env['PATH_INFO'], endpoint)
        end

        # A static-token endpoint keeps the response it has always sent. An
        # endpoint with an authenticator adds the challenge that tells an
        # OAuth client where the endpoint's metadata is and which scopes to
        # request. Its error object has no id member, and its code is
        # Otto::MCP::UNAUTHORIZED rather than one from the JSON-RPC range.
        def unauthorized_response(env, auth)
          headers = { 'content-type' => 'application/json' }
          error   = { code: -32_000, message: 'Unauthorized', data: 'Valid token required' }
          return [401, headers, [JSON.generate({ jsonrpc: '2.0', id: nil, error: error })]] unless auth.respond_to?(:challenge)

          headers['www-authenticate'] = auth.challenge(env)
          [401, headers, [JSON.generate({ jsonrpc: '2.0', error: error.merge(code: Otto::MCP::UNAUTHORIZED) })]]
        end
      end
    end
  end
end
