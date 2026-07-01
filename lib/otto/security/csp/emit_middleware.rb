# lib/otto/security/csp/emit_middleware.rb
#
# frozen_string_literal: true

require 'securerandom'

require_relative '../config'

class Otto
  module Security
    module CSP
      # Rack middleware that applies a nonce-based Content-Security-Policy to
      # HTML responses at the raw response-tuple boundary.
      #
      # This is the reusable "web chokepoint" for nonce-CSP emission: instead of
      # every application hand-rolling the HTML-only / don't-clobber /
      # needs-nonce guards around `@app.call(env)`, mount this middleware and
      # the apply goes through the single casing-safe core
      # {Otto::Security::Config#write_nonce_csp}. A downstream app that returns
      # canonically-cased headers (`Content-Type`, `Content-Security-Policy`)
      # can therefore never silently lose its CSP or end up with a duplicate
      # header. Sibling to {Otto::Security::CSP::ReportMiddleware}, which is the
      # receiving half of Otto's CSP support.
      #
      # Behavior:
      #
      # - INERT unless {Otto::Security::Config#csp_nonce_enabled?} — a
      #   transparent pass-through that touches neither env nor response.
      # - Ensures a per-request nonce in `env[nonce_key]` BEFORE calling the
      #   inner app, so views can embed the same nonce the header will carry. A
      #   nonce already present (set upstream or by the application) is
      #   respected, and the key is configurable so apps with their own
      #   convention (e.g. `env['myapp.nonce']`) can point Otto at it.
      # - Applies the CSP with `clobber: false`: this is a passive backstop
      #   that DEFERS to any CSP the application already set (e.g. via
      #   {Otto::Response#send_csp_headers}, which deliberately overrides).
      # - Only HTML responses (`content-type` starting `text/html`) receive the
      #   header; everything else passes through untouched.
      class EmitMiddleware
        # Default env key the per-request nonce is stored under. Documented in
        # {Otto::EnvKeys::NONCE}.
        NONCE_KEY = 'otto.nonce'

        # @param app [#call] inner Rack app
        # @param config [Otto::Security::Config, nil] security config; the Otto
        #   middleware stack injects the instance's config automatically
        # @param nonce_key [String] env key to read/store the per-request nonce
        # @param development_mode [Boolean] emit development-friendly directives
        def initialize(app, config = nil, nonce_key: NONCE_KEY, development_mode: false)
          @app              = app
          @config           = config || Otto::Security::Config.new
          @nonce_key        = nonce_key
          @development_mode = development_mode
        end

        def call(env)
          return @app.call(env) unless @config.csp_nonce_enabled?

          nonce = (env[@nonce_key] ||= SecureRandom.base64(16))
          status, headers, body = @app.call(env)

          # write_nonce_csp wraps a plain Hash in Rack::Headers, which COPIES —
          # the returned object is the one that carries the header, so it (not
          # the original) goes into the tuple.
          headers = @config.write_nonce_csp(
            headers, nonce,
            development_mode: @development_mode,
            clobber: false
          )
          [status, headers, body]
        end
      end
    end
  end
end
