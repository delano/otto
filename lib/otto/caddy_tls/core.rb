# lib/otto/caddy_tls/core.rb
#
# frozen_string_literal: true

class Otto
  # Otto::CaddyTLS is a modular, opt-in integration for Caddy's on-demand TLS
  # permission endpoint — the HTTP question Caddy asks a backend before it
  # obtains or loads a certificate on demand: "may I serve TLS for this host?".
  #
  # It is structured like Otto::MCP: a self-contained, top-level namespace loaded
  # eagerly but inert until +enable_caddy_tls!+ is called, rather than an
  # always-on concern like Otto::Security / Otto::Privacy. Each such integration
  # gets its own feature-named home (cf. Otto::MCP, Otto::Security::CSP) — Otto
  # deliberately has no generic "services" bucket; genuinely shared mechanism
  # (e.g. the +:outermost+ middleware position) lives in Otto::Core instead.
  module CaddyTLS
    # Public API mixin included into the Otto class. Mirrors Otto::MCP::Core.
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

        @caddy_tls_server ||= Otto::CaddyTLS::Server.new(self)
        @caddy_tls_server.enable!(endpoint: endpoint, localhost_only: localhost_only, permission: permission)
        Otto.logger.info '[CaddyTLS] Enabled Caddy on-demand TLS permission endpoint' if Otto.debug

        self
      end

      # @return [Boolean] whether the Caddy on-demand TLS endpoint is enabled
      def caddy_tls_enabled?
        @caddy_tls_server&.enabled? || false
      end
    end
  end
end
