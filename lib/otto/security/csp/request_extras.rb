# lib/otto/security/csp/request_extras.rb
#
# frozen_string_literal: true

require 'uri'

require_relative 'policy'

class Otto
  module Security
    module CSP
      # Reads and sanitizes request-scoped CSP directive extras from the Rack
      # env (delano/otto#243).
      #
      # This is the opt-in channel for widening CSP directives with values only
      # known at request time: the app enables it at boot with
      # {Otto::Security::Config#enable_csp_request_extras!} (default off — the
      # env key is a write surface any middleware can reach, so it does not
      # exist until boot code says so), then a handler writes a hash of
      # directive name => additional source tokens to
      # `env['otto.csp.extra_directives']` before the response is finalized,
      # and the policy build folds the sanitized survivors in ADDITIVELY (see
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
      # - Directive names are normalized via
      #   {Otto::Security::CSP::Policy.normalize_directive_name} (the same
      #   normalization {Policy.normalize_overrides} applies to boot-time
      #   overrides); blank keys are dropped. Two raw keys that normalize to
      #   the same directive (`'form_action'` and `'form-action'`) have their
      #   token lists merged (union) — nothing is silently overwritten.
      # - {REFUSED_DIRECTIVES} are dropped wholesale. For the `script-src`
      #   family this is defence-in-depth policy, NOT nonce protection: extras
      #   are additive, so the nonce source would survive an append — refusing
      #   the family simply keeps the request channel away from the one
      #   directive class that gates script execution. `default-src` is refused
      #   because widening it widens every unlisted directive at once. Directives
      #   with no value are refused because an appended origin makes the entire
      #   directive malformed; {Policy.append_extra_sources} retains the same
      #   guard for callers that bypass this sanitizer.
      # - Tokens must be ORIGINS: `scheme://host[:port]` with an http/https
      #   scheme and a non-empty host — no path/query/fragment/userinfo, no
      #   whitespace, no `;`/CR/LF, no wildcards, no quotes. Keyword sources
      #   (`'self'`, `'unsafe-inline'`, ...) and scheme sources (`data:`,
      #   `https:`) are rejected. Accepted tokens are normalized to
      #   `scheme://host[:port]` with a downcased host and default ports
      #   omitted. Hosts follow strip-then-validate: a single trailing dot
      #   (the FQDN root form browsers do NOT treat as the same origin) is
      #   stripped before validation, any remaining trailing dot rejects the
      #   token, and a host containing `%` (percent-encoding that URI's host
      #   parser passes through literally) is rejected outright. An explicit
      #   port must fall in 1..65535 — URI accepts arbitrarily large all-digit
      #   ports that no browser can match.
      #
      # Every key/token dropped during sanitization is logged at :warn via
      # {Otto.structured_log} with a distinct reason (`:invalid_shape`,
      # `:refused_directive`, `:not_an_origin`) and privacy-safe request
      # context. Entries dropped later, during the policy append (an absent
      # directive, a valueless directive supplied by a caller that bypassed this
      # sanitizer, or a config without extras support), are logged by
      # {Otto::Security::CSP::Writer} — the same message, `reason:
      # :absent_directive` / `:valueless_directive` /
      # `:config_without_extras_support`.
      module RequestExtras
        # The env key the consuming app writes. Hardcoded on purpose (not
        # configurable) — it is a cross-gem contract; see also
        # Otto::EnvKeys::CSP::EXTRA_DIRECTIVES (require 'otto/env_keys').
        ENV_KEY = 'otto.csp.extra_directives'

        # Directives the request channel refuses to touch, wholesale. See the
        # module docs for why (defence-in-depth for the script family — NOT
        # nonce-stripping, since appends keep the nonce — blast radius for
        # default-src — and invalid syntax for directives with no value).
        # Keep the policy-level guard too: Policy.nonce_policy(extra_directives:)
        # is public and can bypass this sanitizer.
        REFUSED_DIRECTIVES = (
          %w[script-src script-src-elem script-src-attr default-src] +
          Policy::VALUELESS_DIRECTIVES
        ).freeze

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
        #   => normalized origin tokens; nil when the env key is absent, the
        #   value is not a Hash, or nothing survived sanitization — callers
        #   never see an empty hash
        def from_env(env)
          raw = env[ENV_KEY]
          return nil if raw.nil?

          # Compute the request context once per call and thread it through —
          # a hostile payload can produce many drops, and re-deriving the
          # context per token would defeat LoggingHelpers' compute-once-then-
          # merge pattern.
          context = Otto::LoggingHelpers.request_context(env)

          unless raw.is_a?(Hash)
            log_drop(context, directive: nil, token: raw, reason: :invalid_shape)
            return nil
          end

          extras = raw.each_with_object({}) do |(key, value), acc|
            name = Policy.normalize_directive_name(key)
            if name.empty?
              log_drop(context, directive: key, token: value, reason: :invalid_shape)
              next
            end
            if REFUSED_DIRECTIVES.include?(name)
              log_drop(context, directive: name, token: value, reason: :refused_directive)
              next
            end

            tokens = sanitize_tokens(context, name, value)
            next if tokens.empty?

            # Two raw keys can normalize to the same directive ('form_action'
            # and 'form-action'): union the token lists rather than letting
            # the later key silently clobber the earlier one.
            acc[name] = (acc[name] || []) | tokens
          end
          extras.empty? ? nil : extras
        end

        # Sanitize one directive's token value into normalized origin strings.
        # A String value is treated as a whitespace-separated source list (the
        # same ergonomics as a {Policy.merge_directives} String override); an
        # Array is taken element-wise. Anything else drops the key.
        #
        # @param context [Hash] precomputed request context (for log payloads)
        # @param name [String] normalized directive name (for log context)
        # @param value [String, Array<String>, Object]
        # @return [Array<String>] surviving normalized origins (deduplicated)
        def sanitize_tokens(context, name, value)
          candidates =
            case value
            when String then value.split
            when Array then value
            else
              log_drop(context, directive: name, token: value, reason: :invalid_shape)
              return []
            end

          candidates.filter_map do |token|
            unless token.is_a?(String)
              log_drop(context, directive: name, token: token, reason: :invalid_shape)
              next
            end

            normalized = normalize_origin(token)
            if normalized.nil?
              log_drop(context, directive: name, token: token, reason: :not_an_origin)
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
            nil
          end

          return nil unless uri.is_a?(URI::HTTP) # URI::HTTPS is a subclass

          scheme = uri.scheme.to_s.downcase
          return nil unless ALLOWED_SCHEMES.include?(scheme)
          return nil if uri.userinfo
          return nil unless uri.path.to_s.empty?
          return nil if uri.query || uri.fragment

          host = normalize_host(uri.host)
          return nil if host.nil?
          # URI accepts arbitrarily large all-digit ports (and port 0); no
          # browser can match an origin outside the TCP port range, so an
          # out-of-range port is a silent-failure token — reject it. uri.port
          # is never nil for URI::HTTP (defaults apply), and the default ports
          # 80/443 are in range, so one check covers both shapes.
          return nil unless (1..65_535).cover?(uri.port)

          origin = "#{scheme}://#{host}"
          origin << ":#{uri.port}" unless uri.port == uri.default_port
          origin
        end

        # Validate and normalize an origin host: downcased, strip-then-validate
        # for trailing dots (a single trailing dot — the FQDN root form — is
        # stripped, since browsers do not equate `example.com.` with
        # `example.com`; any dot still trailing after the strip rejects the
        # host), and any `%` rejects the host outright (URI's host parser
        # passes percent-encodings through literally, so accepting one would
        # ship raw `%00`-style bytes in a response header).
        #
        # @param raw [String, nil] the parsed URI host
        # @return [String, nil] normalized host, or nil when unacceptable
        def normalize_host(raw)
          host = raw.to_s.downcase
          return nil if host.empty? || host.include?('%')

          host = host.delete_suffix('.')
          return nil if host.empty? || host.end_with?('.')

          host
        end

        # Log one dropped key/token at :warn with privacy-safe request context.
        # Never :debug — drops are actionable signal, and structured_log skips
        # :debug unless Otto.debug is on.
        #
        # @param context [Hash] precomputed request context ({Otto::LoggingHelpers.request_context})
        def log_drop(context, directive:, token:, reason:)
          Otto.structured_log(
            :warn, 'CSP request extra dropped',
            context.merge(
              directive: directive&.to_s,
              token: token.inspect.slice(0, 128),
              reason: reason
            ).compact
          )
        end
      end
    end
  end
end
