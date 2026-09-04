# lib/otto/caddy_tls/localhost_guard.rb
#
# frozen_string_literal: true

require_relative '../utils'

class Otto
  module CaddyTLS
    # Path-scoped Rack middleware that only allows requests to a single
    # endpoint when they originate from the loopback interface.
    #
    # Introduced for the Caddy on-demand TLS endpoint but written to be generic:
    # it protects any single endpoint whose only legitimate caller is a
    # co-located process (a reverse proxy's control-plane callback). Pass it the
    # endpoint path to protect, and it 401s any request to that path whose
    # connecting peer is not loopback. Every other path passes straight through,
    # so installing it never affects the rest of the application. (It lives under
    # Otto::CaddyTLS while it has a single consumer; promote it to a shared home
    # if a second internal-only integration ever needs it.)
    #
    # == Security: authenticate the RAW peer, not the resolved client IP
    #
    # The guard authenticates the TCP socket peer as it arrived, before
    # +IPPrivacyMiddleware+ rewrites +REMOTE_ADDR+ from forwarded headers.
    # +IPPrivacyMiddleware+ is pinned OUTERMOST (issue #219), so it runs ahead
    # of this guard and records its verdict on the untouched peer as
    # +env['otto.peer_loopback']+ — a boolean, never an address. The guard reads
    # that record when present and falls back to evaluating +REMOTE_ADDR+
    # itself when it is not (no Otto privacy middleware in the stack, or the
    # guard mounted outside Otto). Either way the decision is made on the raw
    # peer.
    #
    # Reading Otto's resolved +otto.client_ip+ (or the rewritten +REMOTE_ADDR+)
    # would be exploitable: a co-located reverse proxy on loopback is itself a
    # natural trusted proxy, so an attacker who could reach the endpoint through
    # it and send +X-Forwarded-For: 127.0.0.1+ would be promoted to "localhost".
    # Authenticating the raw peer removes forwarded headers from the trust
    # decision entirely.
    #
    # == What "a direct local call" means
    #
    # The endpoint's only legitimate caller is the co-located service making a
    # *direct* request over the loopback interface. Two things must both hold:
    #
    # 1. The socket peer (+REMOTE_ADDR+) is loopback.
    # 2. The request carries NO forwarding headers. Caddy's on-demand permission
    #    request is a direct backend call and sends none; a request that was
    #    *relayed through a reverse proxy* carries +X-Forwarded-For+ (or a
    #    sibling). Rejecting those is what makes the guard safe even when the
    #    endpoint is accidentally mounted inside a public app behind a proxy that
    #    connects to the backend over loopback — there, every proxied request has
    #    a loopback peer, but it also carries a forwarding header, so it is
    #    denied.
    #
    # == Deployment assumption
    #
    # The guard trusts that +REMOTE_ADDR+ is the real socket peer and that a
    # trusted layer has not stripped forwarding headers before Otto sees them.
    # The strongest isolation is still network-level: bind the endpoint on a
    # dedicated loopback-only port that the proxy reaches directly (see
    # examples/caddy_tls_demo/standalone.ru). Blocking the endpoint path at the
    # proxy is a sound additional layer. See
    # docs/adr/adr-003-caddy-tls-route-based-integration.md.
    class LocalhostGuard
      # Forwarding headers whose presence means the request was relayed by a
      # proxy rather than issued directly. Any one present => not a direct local
      # call. Mirrors Otto::Utils::FORWARDED_FOR_HEADERS plus RFC 7239 Forwarded.
      FORWARDED_HEADERS = %w[
        HTTP_X_FORWARDED_FOR
        HTTP_X_REAL_IP
        HTTP_X_CLIENT_IP
        HTTP_FORWARDED
      ].freeze

      # @param app [#call] the downstream Rack app
      # @param endpoint [String] the path to protect (e.g. '/_caddy/tls-permission')
      def initialize(app, endpoint)
        @app      = app
        @endpoint = normalize_path(endpoint)
      end

      # @param env [Hash] Rack environment
      # @return [Array] Rack response tuple
      def call(env)
        return @app.call(env) unless targets_endpoint?(env)
        return deny unless direct_local_call?(env)

        @app.call(env)
      end

      private

      # A direct local call: loopback socket peer AND no forwarding headers.
      #
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def direct_local_call?(env)
        loopback_peer?(env) && !relayed?(env)
      end

      # Whether any forwarding header is present (request came via a proxy).
      #
      # Unlike the peer check, this reads header STATE, which IPPrivacyMiddleware
      # has already touched by the time the guard runs. That is safe in both of
      # its paths, but only for a reason worth writing down:
      #
      # - Masking REWRITES a forwarded header to the masked IP rather than
      #   removing it, so a relayed request still looks relayed. Correct — it was.
      # - The no-resolvable-client-IP path DELETES them, which would make a
      #   relayed request look direct. That path is reached only when REMOTE_ADDR
      #   is absent or blank, which forces otto.peer_loopback to false, so
      #   #direct_local_call? denies on the peer check before this one matters.
      #
      # So header deletion upstream cannot turn a deny into an allow — but that
      # rests on the peer check failing closed for a blank address. Anything that
      # makes an unresolvable-IP request keep a loopback peer verdict would need
      # to record the relay state pre-scrub too (an otto.peer_relayed sibling to
      # otto.peer_loopback).
      #
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def relayed?(env)
        FORWARDED_HEADERS.any? { |header| !env[header].to_s.strip.empty? }
      end

      # Whether this request is for the protected endpoint. Normalizes
      # +PATH_INFO+ through the same +Otto::Utils.normalize_path+ the router
      # uses for literal matching, so a percent-encoded, invalid-byte, or
      # trailing-slash variant the router would still route cannot slip past the
      # guard by normalizing differently here than at dispatch.
      #
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def targets_endpoint?(env)
        normalize_path(env['PATH_INFO']) == @endpoint
      end

      # Router-equivalent path normalization. Delegates to the single shared
      # implementation so the guard and the router cannot drift (see
      # Otto::Utils.normalize_path).
      #
      # @param path [String, nil]
      # @return [String] normalized path
      def normalize_path(path)
        Otto::Utils.normalize_path(path)
      end

      # Whether the connecting peer is a loopback address.
      #
      # Prefers +env['otto.peer_loopback']+ — IPPrivacyMiddleware's verdict on
      # the ORIGINAL peer, recorded before it rewrites +REMOTE_ADDR+ (it runs
      # outermost, so by the time this guard sees the env the address may
      # already be the resolved-and-masked client IP). Only a real Boolean is
      # honored; anything else falls through to evaluating +REMOTE_ADDR+, which
      # is the correct source when no privacy middleware ran.
      #
      # Both paths share +Otto::Utils.loopback_address?+, so the recorded
      # verdict and the fallback cannot disagree. It fails closed: a blank,
      # ported, or unparseable value is treated as non-loopback (denied) rather
      # than raising on the hot path.
      #
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def loopback_peer?(env)
        recorded = env['otto.peer_loopback']
        return recorded if [true, false].include?(recorded)

        Otto::Utils.loopback_address?(env['REMOTE_ADDR'])
      end

      # @return [Array] 401 Rack response tuple
      def deny
        [401, { 'content-type' => 'text/plain' }, ['Unauthorized']]
      end
    end
  end
end
