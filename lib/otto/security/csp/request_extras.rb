# lib/otto/security/csp/request_extras.rb
#
# frozen_string_literal: true

require 'uri'

class Otto
  module Security
    module CSP
      # Reads and sanitizes request-scoped CSP directive extras from the Rack
      # env (delano/otto#243).
      #
      # This is the opt-in channel for widening CSP directives with values only
      # known at request time: the consuming app writes a hash of directive
      # name => additional source tokens to `env['otto.csp.extra_directives']`
      # before the response is finalized, and the policy build folds the
      # sanitized survivors in ADDITIVELY (see
      # {Otto::Security::CSP::Policy.append_extra_sources}). The motivating
      # case is a multi-tenant app that must admit the resolved tenant's SSO
      # IdP origin into `form-action` — per-request data no boot-time override
      # can express.
      #
      # This module deliberately has the OPPOSITE failure mode of
      # {Otto::Security::CSP::Policy}: Policy is pure functions that raise on
      # bad input (boot-time overrides should fail loud), while request-time
      # extras must NEVER raise — a hostile or malformed value is dropped and
      # logged, and the response still ships with the base policy intact.
      #
      # Sanitization rules:
      # - Directive names are normalized like
      #   {Otto::Security::CSP::Policy.normalize_overrides}
      #   (`to_s.strip.downcase.tr('_', '-')`); blank keys are dropped.
      # - {REFUSED_DIRECTIVES} are dropped wholesale. For the `script-src`
      #   family this is defence-in-depth policy, NOT nonce protection: extras
      #   are additive, so the nonce source would survive an append — refusing
      #   the family simply keeps the request channel away from the one
      #   directive class that gates script execution. `default-src` is refused
      #   because widening it widens every unlisted directive at once.
      # - Tokens must be ORIGINS: `scheme://host[:port]` with an http/https
      #   scheme and a non-empty host — no path/query/fragment/userinfo, no
      #   whitespace, no `;`/CR/LF, no wildcards, no quotes. Keyword sources
      #   (`'self'`, `'unsafe-inline'`, ...) and scheme sources (`data:`,
      #   `https:`) are rejected. Accepted tokens are normalized to
      #   `scheme://host[:port]` with a downcased host and default ports
      #   omitted.
      #
      # Every dropped key/token is logged at :warn via {Otto.structured_log}
      # with a distinct reason (`:invalid_shape`, `:refused_directive`,
      # `:not_an_origin`) and privacy-safe request context.
      module RequestExtras
        # The env key the consuming app writes. Hardcoded on purpose (not
        # configurable) — it is a cross-gem contract; see also
        # Otto::EnvKeys::CSP::EXTRA_DIRECTIVES (require 'otto/env_keys').
        ENV_KEY = 'otto.csp.extra_directives'

        # Directives the request channel refuses to touch, wholesale. See the
        # module docs for why (defence-in-depth for the script family — NOT
        # nonce-stripping, since appends keep the nonce — and blast radius for
        # default-src).
        REFUSED_DIRECTIVES = %w[script-src script-src-elem script-src-attr default-src].freeze

        # The only schemes an extra origin may carry.
        ALLOWED_SCHEMES = %w[http https].freeze

        # Characters that can never appear in an origin token: whitespace and
        # `;`/CR/LF (directive separators), quotes (keyword sources), and `*`
        # (wildcards). Checked before URI parsing so hostile tokens are
        # rejected even when URI would tolerate them.
        FORBIDDEN_CHARS = /[\s;'"*\r\n]/

        module_function

        # Read and sanitize the request-scoped extras from the Rack env.
        #
        # Never raises. Anything that fails validation is dropped and logged;
        # whatever survives is returned.
        #
        # @param env [Hash] the Rack environment
        # @return [Hash{String=>Array<String>}, nil] normalized directive name
        #   => normalized origin tokens; nil when the env key is absent or the
        #   value is not a Hash, possibly empty when everything was dropped
        def from_env(env)
          raw = env[ENV_KEY]
          return nil if raw.nil?

          unless raw.is_a?(Hash)
            log_drop(env, directive: nil, token: raw, reason: :invalid_shape)
            return nil
          end

          raw.each_with_object({}) do |(key, value), acc|
            name = key.to_s.strip.downcase.tr('_', '-')
            if name.empty?
              log_drop(env, directive: key, token: value, reason: :invalid_shape)
              next
            end
            if REFUSED_DIRECTIVES.include?(name)
              log_drop(env, directive: name, token: value, reason: :refused_directive)
              next
            end

            tokens = sanitize_tokens(env, name, value)
            acc[name] = tokens unless tokens.empty?
          end
        end

        # Sanitize one directive's token value into normalized origin strings.
        # A String value is treated as a whitespace-separated source list (the
        # same ergonomics as a {Policy.merge_directives} String override); an
        # Array is taken element-wise. Anything else drops the key.
        #
        # @param env [Hash] the Rack environment (for log context)
        # @param name [String] normalized directive name (for log context)
        # @param value [String, Array<String>, Object]
        # @return [Array<String>] surviving normalized origins (deduplicated)
        def sanitize_tokens(env, name, value)
          candidates =
            case value
            when String then value.split
            when Array then value
            else
              log_drop(env, directive: name, token: value, reason: :invalid_shape)
              return []
            end

          candidates.filter_map do |token|
            unless token.is_a?(String)
              log_drop(env, directive: name, token: token, reason: :invalid_shape)
              next
            end

            normalized = normalize_origin(token)
            if normalized.nil?
              log_drop(env, directive: name, token: token, reason: :not_an_origin)
              next
            end
            normalized
          end.uniq
        end

        # Validate and normalize a single token as an http(s) origin.
        #
        # @param token [String]
        # @return [String, nil] `scheme://host[:port]` (downcased host, default
        #   port omitted), or nil when the token is not an acceptable origin
        def normalize_origin(token)
          return nil if token.empty? || token.match?(FORBIDDEN_CHARS)

          uri = begin
            URI.parse(token)
          rescue URI::InvalidURIError
            return nil
          end

          return nil unless uri.is_a?(URI::HTTP) # URI::HTTPS is a subclass

          scheme = uri.scheme.to_s.downcase
          return nil unless ALLOWED_SCHEMES.include?(scheme)
          return nil if uri.host.nil? || uri.host.empty?
          return nil if uri.userinfo
          return nil unless uri.path.to_s.empty?
          return nil if uri.query || uri.fragment

          origin = +"#{scheme}://#{uri.host.downcase}"
          origin << ":#{uri.port}" unless uri.port == uri.default_port
          origin
        end

        # Log one dropped key/token at :warn with privacy-safe request context.
        # Never :debug — drops are actionable signal, and structured_log skips
        # :debug unless Otto.debug is on.
        def log_drop(env, directive:, token:, reason:)
          Otto.structured_log(
            :warn, 'CSP request extra dropped',
            Otto::LoggingHelpers.request_context(env).merge(
              directive: directive&.to_s,
              token: token.inspect.slice(0, 128),
              reason: reason,
            ).compact
          )
        end
      end
    end
  end
end
