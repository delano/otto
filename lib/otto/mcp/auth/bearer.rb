# lib/otto/mcp/auth/bearer.rb
#
# frozen_string_literal: true

require 'uri'

require_relative 'context'

class Otto
  module MCP
    module Auth
      # Builds the +WWW-Authenticate+ value for an MCP endpoint.
      #
      # Every parameter comes from configuration or from a tool definition.
      # Nothing from the request is echoed.
      module Challenge
        WELL_KNOWN_PATH = '/.well-known/oauth-protected-resource'

        # @param resource_metadata [String, nil] URL of the protected resource
        #   metadata document
        # @param scopes [Array<String>] scopes to name in the challenge
        # @param error [String, nil] an RFC 6750 error code
        # @return [String] e.g. +Bearer resource_metadata="...", scope="a b"+
        def self.bearer(resource_metadata: nil, scopes: [], error: nil)
          params = {
                        error: error,
                        scope: (scopes.join(' ') unless scopes.empty?),
            resource_metadata: resource_metadata,
          }.compact
          return 'Bearer' if params.empty?

          "Bearer #{params.map { |name, value| %(#{name}="#{value.to_s.gsub(/["\\]/) { |char| "\\#{char}" }}") }.join(', ')}"
        end

        # Where the metadata document for +resource_uri+ is published: the
        # well-known path inserted between the host and the resource's path.
        #
        # @param resource_uri [String] canonical URI of the MCP endpoint
        # @return [String]
        def self.metadata_url(resource_uri)
          uri       = URI.parse(resource_uri)
          path      = uri.path.to_s == '/' ? '' : uri.path.to_s
          authority = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
          url       = "#{uri.scheme}://#{authority}#{WELL_KNOWN_PATH}#{path}"
          uri.query ? "#{url}?#{uri.query}" : url
        end
      end

      # Authenticates an MCP request from its +Authorization: Bearer+ header.
      #
      # Otto reads the header and hands the token to the application's
      # verifier, which returns an {Otto::MCP::Auth::Context} for a token it
      # accepts and nil for one it rejects. Otto reads no other header and no
      # query parameter, and it does not log or store the token.
      #
      # When the endpoint has a resource URI, a Context whose audience does
      # not name that URI is rejected, so a token issued for another service
      # cannot be used here even if the verifier accepts it.
      #
      # A verifier that raises is not rescued: an outage in the token store
      # is a server error, never a 401 and never a success.
      class BearerAuth
        # A token longer than this is rejected before the verifier sees it.
        MAX_TOKEN_BYTES = 4096

        # RFC 6750 section 2.1: the scheme, one or more spaces, a b64token.
        # The scheme is compared without regard to case (RFC 9110).
        CREDENTIALS = %r{\ABearer +([A-Za-z0-9\-._~+/]+=*)\s*\z}i

        # @return [String, nil] canonical URI of the endpoint
        attr_reader :resource_uri

        # @return [Array<String>] scopes named in a challenge to a request
        #   that has no valid token
        attr_reader :challenge_scopes

        # @param verifier [#call] takes +(token, env)+
        # @param resource_uri [String, nil]
        # @param challenge_scopes [Array<String>]
        def initialize(verifier, resource_uri: nil, challenge_scopes: [])
          @verifier         = verifier
          @resource_uri     = resource_uri
          @challenge_scopes = challenge_scopes
        end

        # @param env [Hash] Rack env
        # @return [Otto::MCP::Auth::Context, nil]
        # @raise [TypeError] if the verifier returns anything but a Context,
        #   nil or false
        def authenticate(env)
          token = self.class.token(env)
          return nil unless token

          context = @verifier.call(token, env)
          return nil unless context

          unless context.is_a?(Context)
            raise TypeError,
                  "MCP authenticator must return an Otto::MCP::Auth::Context or nil, got #{context.class}"
          end

          return context if @resource_uri.nil? || context.issued_for?(@resource_uri)

          Otto.structured_log(:warn, 'MCP token not issued for this endpoint',
            Otto::LoggingHelpers.request_context(env).merge(resource: @resource_uri, client_id: context.client_id))
          nil
        end

        # @param env [Hash] Rack env
        # @param error [String, nil] RFC 6750 error code
        # @param scopes [Array<String>, nil] scopes to name; the configured
        #   challenge scopes when nil
        # @return [String] the +WWW-Authenticate+ value
        def challenge(env = nil, error: nil, scopes: nil)
          error ||= 'invalid_token' if env && self.class.presented?(env)
          Challenge.bearer(
            resource_metadata: @resource_uri && Challenge.metadata_url(@resource_uri),
            scopes: scopes || @challenge_scopes,
            error: error
          )
        end

        # @param env [Hash] Rack env
        # @return [String, nil] the bearer token, or nil when the header is
        #   absent, uses another scheme, is malformed or is too long
        def self.token(env)
          header = env['HTTP_AUTHORIZATION']
          return nil unless header.is_a?(String) && header.bytesize <= MAX_TOKEN_BYTES + 16

          token = header[CREDENTIALS, 1]
          token if token && token.bytesize <= MAX_TOKEN_BYTES
        end

        # @param env [Hash] Rack env
        # @return [Boolean] true when the request sent a Bearer credential,
        #   valid or not
        def self.presented?(env)
          env['HTTP_AUTHORIZATION'].to_s.match?(/\ABearer(\s|\z)/i)
        end
      end
    end
  end
end
