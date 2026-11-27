# lib/otto/mcp/auth/context.rb
#
# frozen_string_literal: true

require 'json'

class Otto
  module MCP
    module Auth
      # The verified caller of one MCP request.
      #
      # An authenticator returns a Context once it has verified the request's
      # access token. Otto stores it in +env['otto.mcp.auth']+, filters
      # +tools/list+ and +resources/list+ by its scopes, and checks those
      # scopes again on every +tools/call+ and +resources/read+. Handlers read
      # it to enforce ownership and other per-object rules.
      #
      # Every member comes from the authenticator. Otto adds nothing from the
      # request body, and +clientInfo+ in a request's +_meta+ never reaches a
      # Context.
      #
      # @example Returned by an authenticator
      #   Otto::MCP::Auth::Context.new(
      #     subject: claims['sub'],
      #     client_id: claims['client_id'],
      #     tenant: claims['org'],
      #     scopes: claims['scope'],
      #     audience: claims['aud'],
      #   )
      Context = Data.define(:subject, :client_id, :tenant, :scopes, :audience, :claims, :issuer) do
        # @param subject [String] stable identifier of the person or workload
        #   the token was issued for
        # @param client_id [String, nil] the OAuth client the token was issued to
        # @param tenant [String, nil] the organization or account boundary
        # @param scopes [Array<String>, Set<String>, String] granted scopes; a
        #   String is split on spaces, as an OAuth +scope+ claim is written
        # @param audience [Array<String>, String] every resource the token was
        #   issued for, exactly as the authenticator verified it
        # @param claims [Hash] other verified values for handlers; Otto does
        #   not read them
        # @param issuer [String, nil] the authorization server that issued
        #   the token. Give it when the endpoint accepts tokens from more
        #   than one, since two issuers can use the same subject.
        # @raise [ArgumentError] if subject is not a non-blank String
        def initialize(subject:, client_id: nil, tenant: nil, scopes: [], audience: [], claims: {}, issuer: nil)
          named = subject.is_a?(String) && !subject.strip.empty?
          raise ArgumentError, "MCP auth context subject must be a non-blank String, got #{subject.class}" unless named

          super(
            subject: subject.dup.freeze,
            client_id: client_id&.to_s&.freeze,
            tenant: tenant&.to_s&.freeze,
            scopes: (scopes.is_a?(String) ? scopes.split : scopes.to_a).map { |scope| scope.to_s.freeze }.uniq.freeze,
            audience: Array(audience).map { |entry| entry.to_s.freeze }.freeze,
            claims: claims.to_h.freeze,
            issuer: issuer&.to_s&.freeze
          )
        end

        # @param required [Array<String>] scopes a tool or resource requires
        # @return [Boolean] true when every required scope was granted
        def grants?(required)
          (required - scopes).empty?
        end

        # @param resource_uri [String] canonical URI of an MCP endpoint
        # @return [Boolean] true when the token was issued for that endpoint
        def issued_for?(resource_uri)
          audience.include?(resource_uri)
        end

        # Identifies the caller when Otto binds a +requestState+ to it. JSON
        # keeps the members apart whatever characters they contain.
        #
        # @return [String]
        def principal_key
          JSON.generate([issuer, subject, client_id, tenant])
        end

        # Leaves out +claims+, which can contain personal data.
        #
        # @return [String]
        def inspect
          "#<#{self.class.name} issuer=#{issuer.inspect} subject=#{subject.inspect} client_id=#{client_id.inspect} " \
            "tenant=#{tenant.inspect} scopes=#{scopes.inspect} audience=#{audience.inspect}>"
        end
        alias_method :to_s, :inspect
      end
    end
  end
end
