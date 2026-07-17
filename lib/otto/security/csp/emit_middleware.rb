# lib/otto/security/csp/emit_middleware.rb
#
# frozen_string_literal: true

require_relative 'writer'
require_relative 'nonce'

class Otto
  module Security
    module CSP
      # Rack middleware that emits a nonce-based Content-Security-Policy on the
      # way out — the EMITTING sibling of {Otto::Security::CSP::ReportMiddleware}.
      #
      # It is a passive BACKSTOP: it runs the CSP through {Otto::Security::CSP::Writer}
      # in `:backstop` mode, so it fills the gap for responses that would
      # otherwise ship without a CSP but NEVER clobbers one a route or another
      # layer already set. All the emission invariants (enabled / HTML-only /
      # nonce-present / don't-clobber / lowercase key) are the Writer's, so this
      # middleware carries none of that guard logic itself.
      #
      # DEFAULT: emit-if-consumed. It emits only when the request actually
      # consumed a nonce (a view called {Otto::Request#csp_nonce}, memoizing it
      # into the env). This is the safe default: a nonce-only `script-src` on an
      # HTML page whose templates never stamped that nonce would block EVERY
      # script on the page. "CSP responses whose request consumed a nonce" is
      # sound; "CSP all HTML responses" is not.
      #
      # EAGER (opt-in): with `eager: true` it MINTS a nonce for every otherwise
      # eligible response, even one that never touched it. Only safe when the app
      # either uses no nonce-gated inline scripts or stamps the nonce another way;
      # otherwise it reintroduces the blocked-script hazard above.
      #
      # INERT unless {Otto::Security::Config#csp_nonce_enabled?}. When nonce-CSP
      # is off it is a transparent pass-through (and never mints a nonce).
      class EmitMiddleware
        # @param app [#call] the inner Rack app
        # @param config [Otto::Security::Config, nil] security config (the
        #   middleware stack injects this); a nil config yields an inert instance
        # @param eager [Boolean] mint-and-emit for every eligible response rather
        #   than only emit-if-consumed
        # @param development_mode [Boolean, #call, nil] whether to emit the
        #   development directive set. A callable is invoked per request with the
        #   env (e.g. `->(env) { OT.conf.dig('development', 'enabled') }`); a plain
        #   value is used as-is; nil means production.
        def initialize(app, config = nil, eager: false, development_mode: nil)
          @app              = app
          @config           = config || Otto::Security::Config.new
          @eager            = eager
          @development_mode = development_mode
        end

        def call(env)
          status, headers, body = @app.call(env)
          apply_backstop(env, headers) if @config.csp_nonce_enabled?
          [status, headers, body]
        end

        private

        # Resolve the nonce per the eager/consumed policy and, when present, let
        # the Writer apply the backstop CSP. The Writer re-checks every guard, so
        # a non-HTML or already-CSP'd response is left untouched.
        def apply_backstop(env, headers)
          nonce = resolve_nonce(env)
          return if nonce.nil? || nonce.empty?

          Otto::Security::CSP::Writer.apply(
            headers, nonce,
            config: @config, mode: :backstop, development_mode: development_mode?(env)
          )
        end

        # Eager mode mints a nonce for this request; the default emits only a
        # nonce the request already consumed (memoized in env by a view).
        def resolve_nonce(env)
          return Otto::Security::CSP.nonce(env) if @eager
          return Otto::Security::CSP.nonce(env) if Otto::Security::CSP.nonce?(env)

          nil
        end

        def development_mode?(env)
          mode = @development_mode
          return mode.call(env) if mode.respond_to?(:call)

          !!mode
        end
      end
    end
  end
end
