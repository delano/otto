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
      # This middleware runs FIRST in the stack to ensure all downstream
      # middleware and application code receives masked IPs by default.
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

          # Privacy is enabled by default unless explicitly disabled
          @privacy_enabled = @config.enabled?
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
          return @app.call(env) if env.key?('otto.client_ip')

          # Record the connecting peer's trust decision BEFORE any masking, so
          # secure? can authorize X-Forwarded-Proto canonically even after
          # REMOTE_ADDR is rewritten to the masked client IP. Leak-free boolean.
          #
          # This is the trusted-proxy *identity* check only — it is deliberately
          # independent of count-based depth mode. Depth resolves the client IP;
          # it never grants proxy trust for X-Forwarded-Proto (matching the
          # downstream OneTimeSecret behavior).
          env['otto.via_trusted_proxy'] = trusted_proxy?(env['REMOTE_ADDR'])

          if @privacy_enabled
            apply_privacy(env)
          else
            apply_no_privacy(env)
          end

          @app.call(env)
        end

        private

        # Apply privacy settings to environment
        #
        # @param env [Hash] Rack environment
        # Apply privacy settings to environment
        #
        # @param env [Hash] Rack environment
        # Apply privacy settings to environment
        #
        # @param env [Hash] Rack environment
        def apply_privacy(env)
          # Resolve the actual client IP once (handling proxies). This is the
          # canonical resolution step; masking below operates on this value.
          client_ip = resolve_client_ip(env)

          Otto.logger.debug "[IPPrivacyMiddleware] Resolved client IP: #{client_ip}" if Otto.debug

          # No resolvable client IP (REMOTE_ADDR absent or blank, and no trusted
          # forwarded value). There is nothing to mask, and masking would derive
          # a nil masked IP (IPPrivacy.mask_ip returns nil for nil/empty input).
          # Writing that nil back to REMOTE_ADDR / forwarded headers would leave
          # present-but-nil CGI keys, which violate the Rack SPEC and trip
          # Rack::Lint — the same class of bug as the User-Agent/Referer case
          # above (issue #167). Bail out, leaving REMOTE_ADDR untouched (an
          # absent key stays absent; an empty string stays an empty string).
          if client_ip.to_s.empty?
            Otto.logger.debug '[IPPrivacyMiddleware] No resolvable client IP; skipping masking' if Otto.debug
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
              Otto.logger.debug "[IPPrivacyMiddleware] Private/localhost IP exempted: #{client_ip}" if Otto.debug
              return
            end
          end

          # Create privacy-safe fingerprint using the resolved client IP
          # We temporarily set REMOTE_ADDR to the client IP for fingerprint creation
          original_remote_addr = env['REMOTE_ADDR']
          env['REMOTE_ADDR'] = client_ip
          fingerprint = Otto::Privacy::RedactedFingerprint.new(env, @config)
          env['REMOTE_ADDR'] = original_remote_addr

          # Set privacy-safe values in environment
          env['otto.privacy.fingerprint'] = fingerprint
          env['otto.privacy.masked_ip'] = fingerprint.masked_ip
          env['otto.privacy.hashed_ip'] = fingerprint.hashed_ip
          env['otto.privacy.geo_country'] = fingerprint.country

          # CRITICAL: Replace REMOTE_ADDR and forwarded headers with masked values
          # This ensures downstream code (rate limiting, auth, logging, Rack's request.ip)
          # automatically uses the masked values without modification
          env['REMOTE_ADDR'] = fingerprint.masked_ip

          # Canonical client IP downstream reads ("resolve once, read everywhere").
          # Privacy-safe: holds the masked value, never the original public IP.
          env['otto.client_ip'] = fingerprint.masked_ip

          # Replace User-Agent with anonymized version (consistent with IP masking).
          # CRITICAL: Always clear original sensitive data. When anonymization
          # yields nil (no/empty UA), DELETE the key rather than assigning nil:
          # the Rack SPEC requires CGI-style keys (no period) to hold String
          # values, and a present-but-nil HTTP_USER_AGENT trips Rack::Lint.
          # Deleting is also marginally more private — an absent header is
          # indistinguishable from one that was never sent.
          replace_or_delete(env, 'HTTP_USER_AGENT', fingerprint.anonymized_ua)

          # Replace Referer with anonymized version (query params stripped).
          # Same Rack SPEC concern as User-Agent above: delete on nil.
          replace_or_delete(env, 'HTTP_REFERER', fingerprint.referer)

          # Mask X-Forwarded-For headers to prevent leakage
          # Replace with masked IP so proxy resolution logic finds the masked IP
          mask_forwarded_headers(env, fingerprint.masked_ip)

          Otto.logger.debug "[IPPrivacyMiddleware] Masked IP: #{fingerprint.masked_ip}" if Otto.debug

          # NOTE: We deliberately DO NOT set env['otto.original_ip'], env['otto.original_user_agent'],
          # or env['otto.original_referer']. This prevents accidental leakage of the real values.
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

        # Mask X-Forwarded-For and related proxy headers
        #
        # Replaces forwarded IP headers with the masked IP to prevent leakage
        # when downstream code (including Rack's request.ip) parses these headers.
        #
        # @param env [Hash] Rack environment
        # @param masked_ip [String] The masked IP to use as replacement
        def mask_forwarded_headers(env, masked_ip)
          # Replace X-Forwarded-For with masked IP
          # This prevents Rack::Request#ip from finding the real IP
          env['HTTP_X_FORWARDED_FOR'] = masked_ip if env['HTTP_X_FORWARDED_FOR']
          env['HTTP_X_REAL_IP'] = masked_ip if env['HTTP_X_REAL_IP']
          env['HTTP_X_CLIENT_IP'] = masked_ip if env['HTTP_X_CLIENT_IP']

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
          env['otto.client_ip'] = resolve_client_ip(env)

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
