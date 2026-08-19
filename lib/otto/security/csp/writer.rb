# lib/otto/security/csp/writer.rb
#
# frozen_string_literal: true

require_relative 'request_extras'

class Otto
  module Security
    module CSP
      # The single structural apply core for nonce-based Content-Security-Policy
      # emission. Every in-framework surface that writes a nonce CSP onto a
      # response — {Otto::Response#apply_csp}, {Otto::Security::CSP::EmitMiddleware},
      # and the deprecated {Otto::Response#send_csp_headers} shim — routes through
      # {.apply}, so the emission invariants are properties of ONE method rather
      # than guard logic re-implemented (and re-reviewed) at each surface:
      #
      # - **Enabled only.** No header unless the security config has nonce-CSP on.
      # - **Nonce present.** A nil/empty nonce never produces a broken
      #   `script-src 'nonce-'` policy; it skips.
      # - **HTML only.** Non-HTML responses (JSON, redirects, static assets) are
      #   left untouched.
      # - **Passive layers never clobber.** In `:backstop` mode an existing CSP is
      #   deferred to; only an explicit `:override` replaces one.
      #
      # Writes are **in-place and key-scoped**: {.apply} finds any case-variant of
      # the CSP key (Rack 3 mandates lowercase response-header keys, but a
      # canonical-/mixed-cased key from a downstream layer is a spec violation this
      # corrects in place), deletes it, and writes the lowercase key into the
      # CALLER'S headers hash. There is no wrapping, no copy, and no
      # "callers-must-use-the-return-value" contract — the `[status, headers,
      # body]` tuple never needs reassignment. A frozen headers hash therefore
      # fails loud (FrozenError) on write, surfacing the downstream SPEC violation
      # rather than silently dropping the policy.
      #
      # The return is a {Result}, not the headers: `result.applied?`,
      # `result.policy`, `result.skip_reason` give uniform observability across
      # every surface (and drive the optional debug log) without any cleverness to
      # detect "did anything happen".
      class Writer
        # Canonical (lowercase, per Rack 3 SPEC) response-header keys.
        CSP_HEADER = 'content-security-policy'
        CONTENT_TYPE_HEADER = 'content-type'

        # Method#parameters types that declare a keyword parameter (used by
        # {.supports_extra_directives?}).
        KEYWORD_PARAM_TYPES = %i[key keyreq].freeze

        # Emission modes. `:override` is a deliberate per-request call that
        # REPLACES any existing CSP (the caller owns this response's policy).
        # `:backstop` is a passive layer that DEFERS to an existing CSP (it only
        # fills the gap, never clobbers).
        MODES = %i[override backstop].freeze

        # Outcome of an {Writer.apply} call.
        #
        # `applied?` is the single source of truth for "did a header get
        # written". `policy` is the emitted policy on success, or the pre-existing
        # policy when a `:backstop` deferred to one. `skip_reason` is one of
        # `:disabled`, `:blank_nonce`, `:non_html`, `:existing_csp` when skipped,
        # else nil. `extra_directives` carries the request-scoped extras that
        # were ACTUALLY folded into the policy — entries dropped during the
        # append (absent directive) are excluded — or nil when none landed.
        class Result
          # Recognized skip reasons, in the order {Writer.apply} evaluates them.
          SKIP_REASONS = %i[disabled blank_nonce non_html existing_csp].freeze

          attr_reader :policy, :skip_reason, :mode, :extra_directives

          def initialize(applied:, mode:, policy: nil, skip_reason: nil, extra_directives: nil)
            @applied = applied
            @mode = mode
            @policy = policy
            @skip_reason = skip_reason
            @extra_directives = extra_directives
          end

          # Build an "applied" result for a written policy.
          def self.applied(policy, mode:, extra_directives: nil)
            new(applied: true, mode: mode, policy: policy, extra_directives: extra_directives)
          end

          # Build a "skipped" result. `policy` carries the pre-existing policy for
          # the `:existing_csp` case (observability), nil otherwise.
          def self.skipped(reason, mode:, policy: nil)
            new(applied: false, mode: mode, skip_reason: reason, policy: policy)
          end

          # @return [Boolean] true when a CSP header was written
          def applied?
            @applied
          end

          # @return [Boolean] true when no header was written
          def skipped?
            !@applied
          end
        end

        # Apply a nonce-based CSP to the caller's response headers, in place.
        #
        # @param headers [Hash] the Rack response headers hash, mutated in place.
        #   MUST be mutable (Rack 3 SPEC); a frozen hash raises FrozenError.
        # @param nonce [String, nil] the per-request nonce.
        # @param config [Otto::Security::Config, nil] source of the enabled gate
        #   and the policy string ({Otto::Security::Config#generate_nonce_csp}).
        # @param mode [Symbol] one of {MODES}.
        # @param development_mode [Boolean] use the development directive set.
        # @param env [Hash, nil] the Rack environment. When given AND the
        #   config has opted the channel in
        #   ({Otto::Security::Config#enable_csp_request_extras!}), any
        #   request-scoped directive extras the app wrote to
        #   `env['otto.csp.extra_directives']` are sanitized
        #   ({Otto::Security::CSP::RequestExtras.from_env}) and folded
        #   ADDITIVELY into the policy. Nil (surfaces with no env in hand)
        #   simply builds the policy without extras; without the opt-in the
        #   env key is ignored entirely.
        # @return [Result]
        # @raise [ArgumentError] if mode is not one of {MODES}
        # @raise [FrozenError] if a write is attempted against a frozen headers hash
        def self.apply(headers, nonce, config:, mode: :override, development_mode: false, env: nil)
          unless MODES.include?(mode)
            raise ArgumentError, "mode must be one of #{MODES.join(', ')}, got #{mode.inspect}"
          end

          result = evaluate(headers, nonce, config, mode, development_mode, env)
          log_debug(config, result)
          result
        end

        # Guarded core: returns a Result and performs the in-place write when it
        # applies. Guards are evaluated most-fundamental first so the reported
        # skip_reason is stable and meaningful. Request-scoped extras are
        # resolved only once every guard has passed — so a skipped response
        # never logs extras drops for a policy that was never built — and only
        # when the config opted the channel in (see {.resolve_extras}).
        def self.evaluate(headers, nonce, config, mode, development_mode, env)
          return Result.skipped(:disabled, mode: mode) unless enabled?(config)
          return Result.skipped(:blank_nonce, mode: mode) if blank?(nonce)
          return Result.skipped(:non_html, mode: mode) unless html_response?(headers)

          existing = existing_csp(headers)
          return Result.skipped(:existing_csp, mode: mode, policy: existing) if existing && mode == :backstop

          extras = resolve_extras(config, env)
          policy, applied_extras = build_policy(config, nonce, development_mode, extras, env)
          write_csp(headers, policy)
          Result.applied(policy, mode: mode, extra_directives: applied_extras)
        end
        private_class_method :evaluate

        # Build the policy string, folding in the request-scoped extras when
        # the config supports them. Returns `[policy, applied_extras]` where
        # applied_extras is the hash of extras entries that ACTUALLY landed in
        # the policy (nil when none did), as reported back by
        # {Policy.append_extra_sources} through the outcome block — never the
        # pre-append input, so {Result#extra_directives} and the debug log can
        # only claim what happened. Entries the append dropped (absent
        # directive) are logged HERE, the one place with the env in hand, with
        # full request context; Policy stays a pure function of its arguments.
        #
        # Configs are duck-typed (see {.enabled?}): one with the pre-#243
        # `generate_nonce_csp` signature would raise ArgumentError on the
        # `extra_directives:` kwarg at request time — violating the extras
        # channel's never-raises invariant — so the kwarg is passed only when
        # the signature declares it. Otherwise the historical call shape is
        # used and the extras are dropped with a single structured warn
        # (`reason: :config_without_extras_support`).
        def self.build_policy(config, nonce, development_mode, extras, env)
          return [config.generate_nonce_csp(nonce, development_mode: development_mode), nil] if extras.nil?

          unless supports_extra_directives?(config)
            Otto.structured_log(
              :warn, 'CSP request extras dropped',
              Otto::LoggingHelpers.request_context(env).merge(
                directives: extras.keys.join(' '),
                reason: :config_without_extras_support
              )
            )
            return [config.generate_nonce_csp(nonce, development_mode: development_mode), nil]
          end

          applied = nil
          policy = config.generate_nonce_csp(
            nonce, development_mode: development_mode, extra_directives: extras
          ) do |applied_extras, dropped_extras|
            applied = applied_extras unless applied_extras.empty?
            log_dropped_extras(env, dropped_extras)
          end
          [policy, applied]
        end
        private_class_method :build_policy

        # Whether the config's generate_nonce_csp declares the
        # `extra_directives:` keyword (or accepts arbitrary keywords).
        def self.supports_extra_directives?(config)
          parameters = config.method(:generate_nonce_csp).parameters
          parameters.any? { |type, name| KEYWORD_PARAM_TYPES.include?(type) && name == :extra_directives } ||
            parameters.any? { |type, _name| type == :keyrest }
        rescue NameError
          false
        end
        private_class_method :supports_extra_directives?

        # Log each extras entry the policy build dropped as :absent_directive,
        # once per entry, with full request context.
        def self.log_dropped_extras(env, dropped)
          return if dropped.nil? || dropped.empty?

          context = Otto::LoggingHelpers.request_context(env)
          dropped.each do |name, tokens|
            Otto.structured_log(
              :warn, 'CSP request extra dropped',
              context.merge(
                directive: name,
                token: Array(tokens).join(' ').inspect.slice(0, 128),
                reason: :absent_directive
              )
            )
          end
        end
        private_class_method :log_dropped_extras

        # Resolve the request-scoped extras, gated on the boot-time opt-in.
        # The env key is a write surface ANY middleware in the Rack stack can
        # reach — a lower-trust position than boot code — so the channel does
        # not exist until {Otto::Security::Config#enable_csp_request_extras!}
        # was called: when disabled (including duck-typed configs without the
        # predicate) the env key is ignored entirely, with no sanitize work
        # and no logs.
        def self.resolve_extras(config, env)
          return nil unless env
          return nil unless config.respond_to?(:csp_request_extras_enabled?) && config.csp_request_extras_enabled?

          RequestExtras.from_env(env)
        end
        private_class_method :resolve_extras

        # In-place, key-scoped write. Delete any case-variant of the CSP key
        # (correcting a downstream SPEC violation), then write the canonical
        # lowercase key into the caller's hash. Variant keys are collected before
        # deleting so we never mutate the hash while iterating it.
        def self.write_csp(headers, policy)
          variant_keys = headers.keys.select { |key| key != CSP_HEADER && key.to_s.casecmp?(CSP_HEADER) }
          variant_keys.each { |key| headers.delete(key) }
          headers[CSP_HEADER] = policy
        end
        private_class_method :write_csp

        # Whether the config has nonce-CSP enabled (nil/foreign configs are "off").
        def self.enabled?(config)
          config.respond_to?(:csp_nonce_enabled?) && config.csp_nonce_enabled?
        end
        private_class_method :enabled?

        # Whether the response is HTML, by the leading media type of its
        # Content-Type (case-insensitive; charset and other parameters ignored).
        # The media type must be exactly `text/html` — matched on the token
        # before any `;`, so `text/html; charset=utf-8` is HTML but `text/html5`
        # or `text/html-foo` is not. Absent Content-Type is treated as non-HTML:
        # a nonce-only CSP on a response the templates never stamped would block
        # every script.
        def self.html_response?(headers)
          content_type = lookup(headers, CONTENT_TYPE_HEADER)
          return false if content_type.nil?

          media_type = content_type.to_s.split(';', 2).first.to_s.strip.downcase
          media_type == 'text/html'
        end
        private_class_method :html_response?

        # The existing CSP value (any case-variant key), or nil.
        def self.existing_csp(headers)
          lookup(headers, CSP_HEADER)
        end
        private_class_method :existing_csp

        # Case-insensitive header read: fast path for the canonical lowercase key,
        # else a scan for a case-variant.
        def self.lookup(headers, name)
          return headers[name] if headers.key?(name)

          headers.each { |key, value| return value if key.to_s.casecmp?(name) }
          nil
        end
        private_class_method :lookup

        def self.blank?(value)
          value.nil? || value.to_s.empty?
        end
        private_class_method :blank?

        # Uniform debug observability: when the config opts into CSP debugging,
        # log the outcome — applied policy OR skip reason — so "why didn't my page
        # get a CSP?" no longer needs a debugger. When request-scoped extras
        # were folded in, note which directives and how many tokens: the
        # EmitMiddleware backstop is otherwise silent about them, so this is
        # the observable trace that a request's extras actually landed.
        def self.log_debug(config, result)
          return unless config.respond_to?(:debug_csp?) && config.debug_csp?
          return unless defined?(Otto.logger) && Otto.logger

          detail = result.applied? ? "applied (#{result.mode}) #{result.policy}" : "skipped (#{result.skip_reason})"
          if (extras = result.extra_directives)
            detail += " extras[#{extras.keys.join(' ')}](#{extras.each_value.sum(&:length)} tokens)"
          end
          Otto.logger.debug("[CSP] #{detail}")
        end
        private_class_method :log_debug
      end
    end
  end
end
