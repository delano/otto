# lib/otto/security/middleware/ip_privacy_middleware.rb
#
# frozen_string_literal: true

class Otto
  module Security
    module Middleware
      # IP Privacy Middleware
      #
      # Automatically masks IP addresses for privacy by default. Original IPs
      # are never stored unless privacy is explicitly disabled.
      #
      # Otto pins this middleware to the OUTERMOST position of the stack (the
      # :entrypoint tier — see Otto::Core::MiddlewareStack#add_with_position),
      # so it is the first middleware to touch a request and every other
      # middleware, plus the application, reads masked IPs by default. Before
      # #219 it was registered `position: :first`, which is first-in-array and
      # therefore INNERMOST: only the wrapped app saw masked values while every
      # other middleware still saw the raw peer address.
      #
      # Because it now runs ahead of everything, facts about the ORIGINAL peer
      # that downstream code can no longer derive from the (masked) REMOTE_ADDR
      # are recorded first, as leak-free booleans — never as addresses:
      # env['otto.via_trusted_proxy'] and env['otto.peer_loopback'].
      #
      # @example Default behavior (privacy enabled)
      #   # env['REMOTE_ADDR'] is masked to 192.168.1.0
      #   # env['otto.privacy.fingerprint'] contains full anonymized data
      #   # env['otto.original_ip'] is NOT set
      #
      # @example Privacy disabled
      #   otto.disable_ip_privacy!
      #   # env['REMOTE_ADDR'] contains real IP
      #   # env['otto.original_ip'] also contains real IP
      #
      class IPPrivacyMiddleware
        # Initialize IP Privacy middleware
        #
        # @param app [#call] Rack application
        # @param security_config [Otto::Security::Config] Security configuration
        def initialize(app, security_config = nil)
          @app = app
          @security_config = security_config
          @config = security_config&.ip_privacy_config || Otto::Privacy::Config.new
        end

        # Process request with IP privacy
        #
        # @param env [Hash] Rack environment
        # @return [Array] Rack response tuple [status, headers, body]
        def call(env)
          # Idempotency: if a prior IPPrivacyMiddleware pass already resolved the
          # canonical client IP for this request, do not re-resolve or re-mask.
          # This makes stacking two instances (e.g. an app-level mount plus
          # Otto's built-in router mount) order-safe instead of double-masking.
          if env.key?('otto.client_ip')
            ensure_ip_match_present(env)
            return @app.call(env)
          end

          # Record the connecting peer's trust decision BEFORE any masking, so
          # secure? can authorize X-Forwarded-Proto canonically even after
          # REMOTE_ADDR is rewritten to the masked client IP. Leak-free boolean.
          #
          # This is the trusted-proxy *identity* check only — it is deliberately
          # independent of count-based depth mode. Depth resolves the client IP;
          # it never grants proxy trust for X-Forwarded-Proto (matching the
          # downstream OneTimeSecret behavior).
          env['otto.via_trusted_proxy'] = trusted_proxy?(env['REMOTE_ADDR'])

          # Same rationale, for loopback: this middleware runs outermost, so a
          # downstream middleware that must authenticate a DIRECT LOCAL CALL
          # (Otto::CaddyTLS::LocalhostGuard) can no longer read the true socket
          # peer from REMOTE_ADDR. Record the verdict here, on the untouched
          # peer, as a boolean — the address itself is never exposed.
          #
          # Deliberately the raw peer, NOT the resolved client IP: resolution
          # honors forwarded headers from trusted proxies, and a co-located
          # reverse proxy on loopback is itself a natural trusted proxy, so
          # resolving first would let `X-Forwarded-For: 127.0.0.1` promote a
          # remote caller to "localhost".
          env['otto.peer_loopback'] = Otto::Utils.loopback_address?(env['REMOTE_ADDR'])

          if privacy_enabled?
            apply_privacy(env)
          else
            apply_no_privacy(env)
          end

          @app.call(env)
        end

        private

        # Whether IP privacy is on for this request.
        #
        # Read live from the config rather than cached at construction. Otto
        # builds its middleware stack at the end of Otto.new, but
        # configure_ip_privacy stays legal until the first request (the
        # configuration freeze is deferred — see Otto#initialize). A flag
        # captured in #initialize would therefore ignore a post-construction
        # `configure_ip_privacy(profile: :audit)` and keep masking under a
        # profile the operator explicitly turned off. One predicate call per
        # request buys that correctness.
        #
        # @return [Boolean]
        def privacy_enabled?
          @config.enabled?
        end

        # Guarantee env['otto.ip_match'] exists on the idempotent-return path.
        #
        # Every path in this middleware that sets otto.client_ip installs the
        # capability first, so a second IPPrivacyMiddleware pass that reaches
        # this guard finds both keys and leaves the precise closure in place.
        # (The no-resolvable-IP path installs the capability but never sets
        # otto.client_ip, so a second pass re-runs apply_privacy and reinstalls
        # an equivalent fail-closed closure — idempotent, since there is nothing
        # to double-mask.) The gap is out-of-contract writes: otto.client_ip is
        # documented as "Set by: IPPrivacyMiddleware" (see Otto::EnvKeys), but
        # an app or test harness that sets it directly trips the idempotency
        # guard and leaves the advertised capability nil — downstream policy
        # code then raises NoMethodError on nil.
        #
        # The repair installs a fail-closed check, NOT one derived from
        # env['otto.client_ip']. That value may already be masked, and matching
        # a masked address against a narrow CIDR produces false ALLOWs (masked
        # 192.168.1.0 falls inside 192.168.1.0/28 when the real client was
        # .200). A universal deny is the safe verdict; the warning below is
        # what makes it diagnosable instead of a silent lockout.
        #
        # @param env [Hash] Rack environment
        def ensure_ip_match_present(env)
          return if env.key?('otto.ip_match')

          Otto.logger.warn(
            '[IPPrivacyMiddleware] otto.client_ip was set outside this ' \
            'middleware, so otto.ip_match could not be built from the ' \
            'unmasked address; installing a fail-closed check (every CIDR ' \
            'test returns false). Let IPPrivacyMiddleware resolve the client IP.'
          )
          env['otto.ip_match'] = ->(_cidrs) { false }
        end

        # Apply privacy settings to environment
        #
        # @param env [Hash] Rack environment
        def apply_privacy(env)
          # Resolve the actual client IP once (handling proxies). This is the
          # canonical resolution step; masking below operates on this value.
          client_ip = resolve_client_ip(env)

          # Install the verdict-only precision capability while client_ip is
          # still the real address — after this method returns, the raw
          # material is gone (REMOTE_ADDR and forwarded headers rewritten).
          install_ip_match(env, client_ip)

          # There is deliberately no debug line for the resolution itself. It
          # used to interpolate client_ip, which handed back through the log
          # exactly what these profiles withhold from env — and logs travel
          # further than a process does. Stripped of the address it carried no
          # information worth a line: this method only runs on the masking
          # profiles (:masked / :anonymous), and every branch below already logs
          # its own outcome. To trace resolution here, log a derived value (the
          # masked IP, the family, the trusted-proxy verdict) — never the address.

          # No resolvable client IP (REMOTE_ADDR absent or blank, and no trusted
          # forwarded value). There is nothing to mask, and masking would derive
          # a nil masked IP (IPPrivacy.mask_ip returns nil for nil/empty input).
          # Writing that nil back to REMOTE_ADDR / forwarded headers would leave
          # present-but-nil CGI keys, which violate the Rack SPEC and trip
          # Rack::Lint — the same class of bug as the User-Agent/Referer case
          # below (issue #167). Skip the IP-masking work, leaving REMOTE_ADDR
          # untouched (an absent key stays absent; an empty string stays an
          # empty string).
          #
          # The User-Agent/Referer redaction, however, is independent of the
          # client IP, and this middleware's contract is to ALWAYS clear the
          # original sensitive data. So still scrub those headers before
          # bailing — a request with no resolvable IP must not leak an
          # un-anonymized User-Agent or Referer.
          #
          # Likewise, forwarded headers may still carry raw client addresses
          # (e.g. an X-Forwarded-For / Forwarded value with no usable REMOTE_ADDR
          # to anchor resolution). There is no masked IP to rewrite them to, so
          # DELETE them — leaving them would leak the raw address downstream.
          if client_ip.to_s.empty?
            Otto.logger.debug '[IPPrivacyMiddleware] No resolvable client IP; skipping IP masking' if Otto.debug
            scrub_sensitive_headers(
              env,
              Otto::Privacy::RedactedFingerprint.new(env, @config, geo_headers_trusted: geo_headers_trusted?(env))
            )
            scrub_forwarded_headers(env)
            return
          end

          # Skip masking for private/localhost IPs unless explicitly configured to mask them
          # This provides better DX for development while still protecting public IPs
          unless @config.mask_private_ips
            if Otto::Privacy::IPPrivacy.private_or_localhost?(client_ip)
              # Update REMOTE_ADDR to the resolved client IP (even though it's not masked)
              env['REMOTE_ADDR'] = client_ip
              env['otto.original_ip'] = client_ip
              # Canonical client IP downstream reads (exempt: not masked)
              env['otto.client_ip'] = client_ip
              # Don't mask forwarded headers for private IPs
              #
              # This early return also means NONE of the privacy fingerprint
              # values are produced for exempt IPs — no otto.privacy.fingerprint,
              # masked_ip, hashed_ip, geo_country, or correlation_hash. That is
              # intentional and consistent: the correlation hash targets public
              # audit-trail traffic, so req.ip_correlation_hash is nil for
              # localhost / RFC-1918 addresses (the default dev path) even when a
              # correlation_secret is configured. Set mask_private_ips to treat
              # private IPs as public and run them through the full path below.
              # No address interpolated (see the resolution note at the top of
              # this method). Exempt IPs skip fingerprinting entirely, so there
              # is no derived value to log either — the line records only that
              # the exemption fired. The address is not lost to debugging: this
              # path leaves REMOTE_ADDR unmasked and sets otto.client_ip to the
              # same value, so downstream request logs still carry it.
              Otto.logger.debug '[IPPrivacyMiddleware] Private/localhost IP exempted from masking' if Otto.debug
              return
            end
          end

          # Create privacy-safe fingerprint using the resolved client IP
          # We temporarily set REMOTE_ADDR to the client IP for fingerprint creation
          original_remote_addr = env['REMOTE_ADDR']
          env['REMOTE_ADDR'] = client_ip
          fingerprint = Otto::Privacy::RedactedFingerprint.new(
            env, @config, geo_headers_trusted: geo_headers_trusted?(env)
          )
          env['REMOTE_ADDR'] = original_remote_addr

          # Set privacy-safe values in environment
          env['otto.privacy.fingerprint'] = fingerprint
          env['otto.privacy.masked_ip'] = fingerprint.masked_ip
          env['otto.privacy.hashed_ip'] = fingerprint.hashed_ip
          env['otto.privacy.geo_country'] = fingerprint.country

          # Fingerprint the FULL client IP here — while client_ip is still the
          # real address, before REMOTE_ADDR is masked below — so it identifies
          # the visitor, not just their /24. Uses the caller's stable secret
          # (unlike hashed_ip's daily key), so the same IP matches across days.
          # nil when no secret is set. The real IP is never written to env; only
          # this hash leaves the middleware.
          env['otto.privacy.correlation_hash'] = correlation_hash(client_ip)

          # CRITICAL: Replace REMOTE_ADDR and forwarded headers with masked values
          # This ensures downstream code (rate limiting, auth, logging, Rack's request.ip)
          # automatically uses the masked values without modification
          env['REMOTE_ADDR'] = fingerprint.masked_ip

          # Canonical client IP downstream reads ("resolve once, read everywhere").
          # Privacy-safe: holds the masked value, never the original public IP.
          env['otto.client_ip'] = fingerprint.masked_ip

          # Replace User-Agent / Referer with anonymized versions (consistent
          # with IP masking). See scrub_sensitive_headers — also reached by the
          # no-resolvable-IP path so these headers are always cleared.
          scrub_sensitive_headers(env, fingerprint)

          # Mask X-Forwarded-For headers to prevent leakage
          # Replace with masked IP so proxy resolution logic finds the masked IP
          mask_forwarded_headers(env, fingerprint.masked_ip)

          Otto.logger.debug "[IPPrivacyMiddleware] Masked IP: #{fingerprint.masked_ip}" if Otto.debug

          # NOTE: We deliberately DO NOT set env['otto.original_ip'], env['otto.original_user_agent'],
          # or env['otto.original_referer']. This prevents accidental leakage of the real values.
        end

        # Fingerprint of the full client IP, keyed with the caller's stable
        # correlation secret (not hashed_ip's daily-rotating key). The same IP
        # and secret always produce the same value, so it can match a visitor
        # across days — which the daily hash can't.
        #
        # Returns nil when no secret is configured. An empty key is never used
        # to hash (that would let anyone reverse it); we return nil rather than
        # raise, since "no secret" just means the feature is off.
        #
        # @param client_ip [String] Resolved full client IP (pre-masking)
        # @return [String, nil] Hex HMAC-SHA256 digest, or nil when unconfigured
        def correlation_hash(client_ip)
          secret = @config.correlation_secret
          return nil if secret.nil? || secret.empty?

          Otto::Privacy::IPPrivacy.hash_ip(client_ip, secret)
        end

        # Set or clear a Rack env header in a SPEC-compliant way.
        #
        # CGI-style keys (those without a period) must hold String values per
        # the Rack SPEC; a present-but-nil value trips Rack::Lint. So when the
        # anonymized replacement is nil, delete the key entirely instead of
        # assigning nil — semantically identical to "cleared" for downstream
        # readers, and SPEC-compliant.
        #
        # @param env [Hash] Rack environment
        # @param key [String] Env key to set or delete
        # @param value [String, nil] Replacement value, or nil to clear the key
        def replace_or_delete(env, key, value)
          if value.nil?
            env.delete(key)
          else
            env[key] = value
          end
        end

        # Redact the request's sensitive non-IP headers in place.
        #
        # User-Agent and Referer carry identifying information independent of
        # the client IP, so they are scrubbed on every privacy-enabled request
        # — including ones with no resolvable IP, where IP masking is skipped.
        # Each header is replaced with the fingerprint's anonymized value, or
        # DELETED when that value is nil (no/empty header): CGI-style keys must
        # hold String values per the Rack SPEC, so a present-but-nil
        # HTTP_USER_AGENT/HTTP_REFERER would trip Rack::Lint (issue #167).
        # Deleting is also marginally more private — an absent header is
        # indistinguishable from one that was never sent.
        #
        # @param env [Hash] Rack environment
        # @param fingerprint [Otto::Privacy::RedactedFingerprint] source of the
        #   anonymized header values
        def scrub_sensitive_headers(env, fingerprint)
          replace_or_delete(env, 'HTTP_USER_AGENT', fingerprint.anonymized_ua)
          replace_or_delete(env, 'HTTP_REFERER', fingerprint.referer)
        end

        # Resolve the actual client IP address from the request.
        #
        # Delegates to the shared Otto::Utils.resolve_client_ip so the
        # middleware ("resolve once") and Otto::Request#client_ipaddress (its
        # no-middleware fallback) use one canonical proxy-chain resolver and
        # cannot drift on which headers are trusted.
        #
        # @param env [Hash] Rack environment
        # @return [String] Resolved client IP address
        def resolve_client_ip(env)
          Otto::Utils.resolve_client_ip(env, @security_config)
        end

        # Install env['otto.ip_match']: a verdict-only CIDR membership check
        # over the resolved, UNMASKED client IP.
        #
        # This is the precision axis of the privacy design, decoupled from the
        # observability axis (the privacy profile): policy code downstream —
        # e.g. a per-tenant IP allowlist — can ask "is this client inside
        # these ranges?" at full /32-/128 precision under ANY profile,
        # including full masking. The unmasked address itself never lands in
        # env; only this closure does, and a closure serializes to nothing
        # useful, so env dumps, loggers, and error reporters that walk env
        # cannot leak the IP accidentally.
        #
        # Threat model: the capability is a membership oracle, so deliberate
        # in-process code could reconstruct the address via adaptive queries —
        # but in-process code is already trusted (it could monkeypatch this
        # middleware). The invariant defended is accidental persistence and
        # serialization, and a Proc preserves it where a raw string could not.
        #
        # The closure is installed on every path that resolves an IP (masked,
        # private-exempt, and privacy-disabled). When the request has no
        # resolvable client IP the check returns false — fail-closed for
        # allowlist callers. Invalid CIDR entries raise (configuration error);
        # see Otto::Utils.ip_in_cidrs?.
        #
        # @param env [Hash] Rack environment
        # @param client_ip [String, nil] resolved, unmasked client IP
        def install_ip_match(env, client_ip)
          env['otto.ip_match'] = ->(cidrs) { Otto::Utils.ip_in_cidrs?(client_ip, cidrs) }
        end

        # Delete forwarded IP headers outright.
        #
        # Used on the no-resolvable-client-IP path, where there is no masked IP
        # to rewrite these to. Leaving them would leak a raw client address (in
        # X-Forwarded-For / X-Real-IP / X-Client-IP / RFC 7239 Forwarded)
        # downstream. Deleting is Rack-SPEC-safe: an absent CGI key is valid.
        #
        # @param env [Hash] Rack environment
        def scrub_forwarded_headers(env)
          env.delete('HTTP_X_FORWARDED_FOR')
          env.delete('HTTP_X_REAL_IP')
          env.delete('HTTP_X_CLIENT_IP')
          env.delete('HTTP_FORWARDED')
        end

        # Mask X-Forwarded-For and related proxy headers
        #
        # Replaces forwarded IP headers with the masked IP to prevent leakage
        # when downstream code (including Rack's request.ip) parses these headers.
        #
        # @param env [Hash] Rack environment
        # @param masked_ip [String] The masked IP to use as replacement
        def mask_forwarded_headers(env, masked_ip)
          # Defensive: never write a nil replacement into these CGI-style headers
          # (the Rack SPEC requires String values; a nil trips Rack::Lint — see
          # issue #167). apply_privacy's early "no client IP" guard already
          # guarantees a non-nil masked_ip here, but keep this method
          # self-contained so a future caller change can't reintroduce a
          # present-but-nil HTTP_X_FORWARDED_FOR.
          return if masked_ip.nil?

          # Replace X-Forwarded-For with masked IP
          # This prevents Rack::Request#ip from finding the real IP
          env['HTTP_X_FORWARDED_FOR'] = masked_ip if env['HTTP_X_FORWARDED_FOR']
          env['HTTP_X_REAL_IP'] = masked_ip if env['HTTP_X_REAL_IP']
          env['HTTP_X_CLIENT_IP'] = masked_ip if env['HTTP_X_CLIENT_IP']

          # RFC 7239 Forwarded carries the client IP in a structured `for=`
          # token, and Otto reads it as an authoritative client-IP source in
          # count-based depth mode (trusted_proxy_header 'Forwarded'/'Both').
          # Left as-is it would leak the real IP to downstream code. Redact only
          # the `for=` value(s) so proto=/host=/by= metadata survives.
          if env['HTTP_FORWARDED']
            env['HTTP_FORWARDED'] = Otto::Privacy::IPPrivacy.mask_forwarded_for(env['HTTP_FORWARDED'], masked_ip)
          end

          Otto.logger.debug "[IPPrivacyMiddleware] Masked forwarded headers" if Otto.debug
        end

        # Check if an IP is from a trusted proxy
        #
        # @param ip [String] IP address to check
        # @return [Boolean] true if IP is from a trusted proxy
        def trusted_proxy?(ip)
          return false unless @security_config

          @security_config.trusted_proxy?(ip)
        end

        # Whether request geo headers may be trusted for this request.
        #
        # Geo headers (CF-IPCountry and friends, plus any app-configured header)
        # are client-spoofable unless the request actually arrived through the
        # CDN/proxy that sets them. So Otto trusts them ONLY when it can verify
        # that origin: a request that arrived via a configured CIDR trusted
        # proxy (identity checked against REMOTE_ADDR).
        #
        # Every other case is untrusted, and geo falls to the local database /
        # custom resolver:
        # - Count-based depth mode: the hop setting the header can't be verified
        #   as a geo-CDN (depth proxies are often plain load balancers), and
        #   depth configures no CIDR matchers, so trusted_proxies_configured? is
        #   false here too.
        # - No trusted-proxy configuration: the header is client-supplied and
        #   unverifiable. Deployments behind a real CDN should configure
        #   trusted_proxies (or a local database) to get header-based geo.
        #
        # @param env [Hash] Rack environment
        # @return [Boolean]
        def geo_headers_trusted?(env)
          sc = @security_config
          return false unless sc.respond_to?(:trusted_proxies_configured?)
          return false unless sc.trusted_proxies_configured?

          env['otto.via_trusted_proxy'] == true
        end

        # Apply no-privacy settings (privacy explicitly disabled)
        #
        # When privacy is disabled, original IP is available for
        # backward compatibility with code that requires it.
        #
        # @param env [Hash] Rack environment
        def apply_no_privacy(env)
          # Resolve the canonical client IP once, even with privacy disabled, so
          # downstream code can read env['otto.client_ip'] instead of re-deriving
          # it from REMOTE_ADDR / forwarded headers.
          client_ip = resolve_client_ip(env)
          env['otto.client_ip'] = client_ip

          # Same precision capability as the privacy-enabled paths, so policy
          # code has one interface regardless of profile.
          install_ip_match(env, client_ip)

          # Store original values for explicit access when privacy is disabled
          if env['REMOTE_ADDR']
            env['otto.original_ip'] = env['REMOTE_ADDR'].dup.force_encoding('UTF-8')
          end

          if env['HTTP_USER_AGENT']
            env['otto.original_user_agent'] = env['HTTP_USER_AGENT'].dup.force_encoding('UTF-8')
          end

          if env['HTTP_REFERER']
            env['otto.original_referer'] = env['HTTP_REFERER'].dup.force_encoding('UTF-8')
          end

          # env['REMOTE_ADDR'], env['HTTP_USER_AGENT'], env['HTTP_REFERER'] remain unchanged (real values)
          # No fingerprint is created when privacy is disabled
        end
      end
    end
  end
end
