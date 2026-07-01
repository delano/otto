# lib/otto/caddy_tls/server.rb
#
# frozen_string_literal: true

require_relative '../route'
require_relative '../utils'
require_relative 'localhost_guard'

class Otto
  module CaddyTLS
    # Registers the permission route and (by default) the localhost guard,
    # and wraps the app-supplied decision block with fail-closed semantics.
    #
    # Mirrors +Otto::MCP::Server+: a small per-integration object that owns
    # its route and middleware registration and is referenced by its handler.
    class Server
      # @return [Otto] the owning Otto instance
      attr_reader :otto

      # @return [String, nil] the registered endpoint path
      attr_reader :endpoint

      # @param otto [Otto] the owning Otto instance
      def initialize(otto)
        @otto    = otto
        @enabled = false
      end

      # @return [Boolean]
      def enabled?
        @enabled
      end

      # Enable the integration. Idempotent: a second call is ignored so the
      # route and guard are never duplicated.
      #
      # @param endpoint [String] path to serve (registered programmatically)
      # @param localhost_only [Boolean] install the loopback guard (default true)
      # @param permission [#call] block receiving the domain, returning truthy to allow
      # @return [void]
      def enable!(endpoint:, localhost_only:, permission:)
        return if @enabled

        # Normalize once so the guard's endpoint, the router's literal-route
        # key, and @endpoint all agree. Without this, a configured trailing
        # slash (or percent-encoding) registers a literal route the router can
        # never match — requests are normalized before lookup — while the guard
        # still targets it, so Caddy would get a denial instead of a decision.
        endpoint = Otto::Utils.normalize_path(endpoint)

        @endpoint       = endpoint
        @permission     = permission
        @localhost_only = localhost_only
        @enabled        = true

        register_route(endpoint)

        if localhost_only
          # SECURITY: appended (via #use) so it is OUTERMOST in the stack and
          # runs BEFORE IPPrivacyMiddleware — the guard must see the raw socket
          # peer, not the forwarded-header-resolved client IP. See LocalhostGuard.
          @otto.use(Otto::CaddyTLS::LocalhostGuard, endpoint)
        else
          # Explicit opt-out: the endpoint then has no built-in access control,
          # so it must be isolated at the network layer. Surface that at setup.
          Otto.structured_log(:warn,
            '[CaddyTLS] localhost guard disabled (localhost_only: false); endpoint is ' \
            'reachable by any client that can reach this app — ensure network-level isolation',
            endpoint: endpoint)
        end

        # structured_log self-skips :debug unless Otto.debug is set.
        Otto.structured_log(:debug, '[CaddyTLS] enabled',
          endpoint: endpoint, localhost_only: localhost_only)
      end

      # Fail-closed decision wrapper. Any exception, +nil+, or +false+ from the
      # app block denies — a broken decision must never authorize a cert.
      #
      # @param domain [String] the domain Caddy is asking about
      # @return [Boolean] true to allow (200), false to deny (403)
      def permit?(domain)
        !!@permission.call(domain)
      rescue StandardError => e
        Otto.structured_log(:error, '[CaddyTLS] permission callback raised; denying',
          domain: domain, error: e.message, error_class: e.class.name)
        false
      end

      private

      # Register the GET route programmatically (like MCP's /_mcp endpoint),
      # so enabling is purely code-side with no routes.txt entry required.
      #
      # @param endpoint [String]
      # @return [void]
      def register_route(endpoint)
        route      = Otto::Route.new('GET', endpoint, 'Otto::CaddyTLS::PermissionHandler.handle')
        route.otto = @otto

        (@otto.routes[:GET] ||= []) << route
        (@otto.routes_literal[:GET] ||= {})[endpoint] = route
      end
    end

    # Class-method route handler for the permission endpoint.
    #
    # The owning Server is resolved per-request from the Otto instance the
    # dispatcher binds to this class (+Otto::Route::ClassMethods#otto+), NOT a
    # class-level global. That keeps multiple Otto instances in one process
    # isolated: each endpoint consults its own permission block. (This shares
    # the same per-request class-accessor mechanism the rest of Otto uses for
    # class-method handlers.)
    class PermissionHandler
      # Handle a permission request. Only +?domain=+ is consulted — no other
      # query parameter reaches the decision. A non-string +domain+ (e.g.
      # +?domain[]=a+) is treated as missing rather than coerced.
      #
      # @param req [Otto::Request]
      # @param res [Otto::Response]
      # @return [Otto::Response]
      def self.handle(req, res)
        raw    = req.params['domain']
        domain = raw.is_a?(String) ? raw.strip : ''

        return respond(req, res, 400, 'Bad Request - domain parameter required') if domain.empty?

        server  = respond_to?(:otto) ? otto&.caddy_tls_server : nil
        allowed = server ? server.permit?(domain) : false
        Otto.structured_log(:info, '[CaddyTLS] permission decision', domain: domain, allowed: allowed)

        respond(req, res, allowed ? 200 : 403, allowed ? 'OK' : 'Forbidden')
      end

      # @param req [Otto::Request]
      # @param res [Otto::Response]
      # @param status [Integer]
      # @param body [String]
      # @return [Otto::Response]
      def self.respond(req, res, status, body)
        res.status          = status
        res['content-type'] = 'text/plain'
        # HEAD must carry no body (Rack SPEC / Rack::Lint); headers still apply.
        res.body            = req.head? ? [] : [body]
        res
      end
    end
  end
end
