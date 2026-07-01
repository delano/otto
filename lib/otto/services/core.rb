# lib/otto/services/core.rb
#
# frozen_string_literal: true

class Otto
  # Otto::Services is the home for modular network-service integrations:
  # small, optional, turnkey features that expose an HTTP surface consumed by
  # an external network component (a reverse proxy, TLS layer, browser reporter,
  # etc.). Each integration is opt-in and self-contained — enabling one never
  # loads another — mirroring how Otto::MCP is structured rather than the
  # always-on Otto::Security / Otto::Privacy concerns.
  #
  # The pilot integration is the Caddy on-demand TLS permission endpoint
  # (see Otto::Services::CaddyTLS). Future integrations (e.g. a CSP violation
  # reporting endpoint) add another +enable_*!+ verb here without new
  # architecture.
  module Services
    # Public API mixin included into the Otto class. Aggregates the small
    # +enable_*!+ / +*_enabled?+ methods for all network-service integrations,
    # so Otto gains one +include+, not one per integration. Mirrors
    # Otto::MCP::Core.
    module Core
      # Enable the Caddy on-demand TLS permission endpoint.
      #
      # Registers a GET endpoint that answers Caddy's on-demand certificate
      # question. The block you pass is the ONLY application coupling point: it
      # receives the requested domain and returns truthy to allow a certificate
      # (HTTP 200) or falsy to deny (HTTP 403). Any exception raised inside the
      # block is caught and treated as a denial (fail-closed).
      #
      # @param endpoint [String] path to serve (default '/_caddy/tls-permission')
      # @param localhost_only [Boolean] install the loopback-only guard (default true)
      # @yieldparam domain [String] the domain Caddy is asking about
      # @yieldreturn [Boolean] truthy to allow (200), falsy to deny (403)
      # @return [self]
      # @raise [ArgumentError] if no permission block is given (no allow-all default)
      # @raise [FrozenError] if called after configuration is frozen
      #
      # @example
      #   otto = Otto.new('routes.txt')
      #   otto.enable_caddy_tls! do |domain|
      #     MyApp::CustomDomain.verified?(domain)
      #   end
      def enable_caddy_tls!(endpoint: '/_caddy/tls-permission', localhost_only: true, &permission)
        ensure_not_frozen!
        raise ArgumentError, 'enable_caddy_tls! requires a permission block' unless block_given?

        @caddy_tls_server ||= Otto::Services::CaddyTLS::Server.new(self)
        @caddy_tls_server.enable!(endpoint: endpoint, localhost_only: localhost_only, permission: permission)
        Otto.logger.info '[Services] Enabled Caddy on-demand TLS permission endpoint' if Otto.debug

        self
      end

      # @return [Boolean] whether the Caddy on-demand TLS endpoint is enabled
      def caddy_tls_enabled?
        @caddy_tls_server&.enabled? || false
      end
    end
  end
end
