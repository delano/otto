# lib/otto/security/csp/nonce.rb
#
# frozen_string_literal: true

require 'securerandom'

class Otto
  module Security
    # Content-Security-Policy support. The framework-owned lazy nonce accessor
    # lives directly on this module ({.nonce} / {.nonce?}), beside the {Policy}
    # builder, the {Writer} apply core, the {Parser}, and the report/emit
    # middlewares.
    module CSP
      # Default Rack env key the per-request nonce is memoized under. Registered
      # as documentation in {Otto::EnvKeys::NONCE}; per that module's convention
      # the string literal (not the constant) is what the codebase passes around,
      # so this DEFAULT_NONCE_KEY exists for the CSP code's own use and the two
      # are kept identical.
      DEFAULT_NONCE_KEY = 'otto.nonce'

      module_function

      # Framework-owned, request-scoped, LAZY CSP nonce.
      #
      # Generates a fresh base64 nonce on first access and memoizes it into the
      # request env under the resolved key, so every later reader observes ONE
      # value: the views that stamp `nonce="…"` onto `<script>`/`<link>` tags and
      # the {Otto::Security::CSP::EmitMiddleware} that writes the `script-src
      # 'nonce-…'` header both read it here. The header's nonce matching the
      # views' nonce is therefore a STRUCTURAL property, not a convention each app
      # re-implements (Rails' `request.content_security_policy_nonce` model).
      #
      # An untouched request never generates a nonce and pays nothing — which is
      # also why the emit-if-consumed middleware is safe: it only emits a
      # nonce-only policy for a request whose views actually consumed the nonce.
      #
      # A value already present under the key (e.g. an app that still mints its
      # own under the same convention) is honored, not overwritten.
      #
      # @param env [Hash] the Rack request env (mutated: the nonce is memoized in)
      # @param key [String, nil] override the env key; nil resolves it from the
      #   security config's {Otto::Security::Config#csp_nonce_key} (or the default)
      # @return [String] the request's nonce
      def nonce(env, key: nil)
        resolved = key || nonce_key(env)
        existing = env[resolved]
        return existing if existing && !existing.empty?

        env[resolved] = SecureRandom.base64(16)
      end

      # Whether a nonce was already minted for this request, WITHOUT minting one.
      # This is the emit-if-consumed predicate.
      #
      # @param env [Hash]
      # @param key [String, nil] see {.nonce}
      # @return [Boolean]
      def nonce?(env, key: nil)
        value = env[key || nonce_key(env)]
        !value.nil? && !value.empty?
      end

      # The env key the nonce lives under: the app's configured convention
      # ({Otto::Security::Config#csp_nonce_key}) when a security config is present
      # on the env, else the framework default. Lets an app with an existing
      # convention (e.g. `onetime.nonce`) adopt the accessor without renaming its
      # env key.
      #
      # @param env [Hash]
      # @return [String]
      def nonce_key(env)
        config = env['otto.security_config']
        configured = config.csp_nonce_key if config.respond_to?(:csp_nonce_key)
        configured && !configured.empty? ? configured : DEFAULT_NONCE_KEY
      end
    end
  end
end
