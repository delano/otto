# lib/otto/services/localhost_guard.rb
#
# frozen_string_literal: true

require 'ipaddr'
require 'rack/utils'

class Otto
  module Services
    # Path-scoped Rack middleware that only allows requests to a single
    # endpoint when they originate from the loopback interface.
    #
    # This is the shared building block for network-service integrations whose
    # only legitimate caller is a co-located process (e.g. a reverse proxy's
    # control-plane callback). It is deliberately generic: pass it the endpoint
    # path to protect, and it 401s any request to that path whose connecting
    # peer is not loopback. Every other path passes straight through, so
    # installing it never affects the rest of the application.
    #
    # == Security: authenticate the RAW peer, not the resolved client IP
    #
    # The guard reads the ORIGINAL +env['REMOTE_ADDR']+ — the TCP socket peer —
    # and MUST run before +IPPrivacyMiddleware+ rewrites +REMOTE_ADDR+ from
    # forwarded headers. Installed via +Otto#use+ (appended, hence outermost in
    # the reduce-built stack) it always executes ahead of +IPPrivacyMiddleware+
    # (which is pinned innermost), so it inspects the true socket peer.
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
    # proxy is a sound additional layer. See docs/reverse-proxy-network-services.md.
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
        loopback_peer?(env['REMOTE_ADDR']) && !relayed?(env)
      end

      # Whether any forwarding header is present (request came via a proxy).
      #
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def relayed?(env)
        FORWARDED_HEADERS.any? { |header| !env[header].to_s.strip.empty? }
      end

      # Whether this request is for the protected endpoint. Normalizes
      # +PATH_INFO+ exactly as the router does (URL-unescape, replace invalid
      # UTF-8 bytes, strip trailing slashes) so a percent-encoded, invalid-byte,
      # or trailing-slash variant that the router would still route cannot slip
      # past the guard by normalizing differently here than at dispatch.
      #
      # @param env [Hash] Rack environment
      # @return [Boolean]
      def targets_endpoint?(env)
        normalize_path(env['PATH_INFO']) == @endpoint
      end

      # @param path [String, nil]
      # @return [String] router-equivalent normalized path
      def normalize_path(path)
        decoded =
          begin
            Rack::Utils.unescape(path.to_s)
          rescue StandardError
            path.to_s
          end
        # Match the router: drop invalid/undefined bytes rather than keep them,
        # so a crafted invalid byte cannot make the guard and router disagree.
        decoded = decoded.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
        decoded.gsub(%r{/+$}, '')
      end

      # Whether the connecting peer is a loopback address. Fails closed: a
      # blank or otherwise unparseable value is treated as non-loopback
      # (denied) rather than raising on the hot path.
      #
      # +.native+ folds IPv4-mapped IPv6 (+::ffff:127.0.0.1+, which dual-stack
      # servers commonly present) so it is correctly recognized as loopback;
      # plain +IPAddr#loopback?+ returns false for the mapped form.
      #
      # A conforming Rack server sets +REMOTE_ADDR+ to a bare IP (the peer's
      # port lives in +REMOTE_PORT+). We deliberately do NOT strip a +:port+
      # suffix here: an unexpected format is a signal something upstream is
      # non-standard, so denying (fail-closed) is safer than coercing it.
      #
      # @param remote_addr [String, nil] the raw socket peer address
      # @return [Boolean]
      def loopback_peer?(remote_addr)
        addr = remote_addr.to_s.strip
        return false if addr.empty?

        IPAddr.new(addr).native.loopback?
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        false
      end

      # @return [Array] 401 Rack response tuple
      def deny
        [401, { 'content-type' => 'text/plain' }, ['Unauthorized']]
      end
    end
  end
end
