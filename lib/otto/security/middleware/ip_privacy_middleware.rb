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
      #   # env['otto.redacted_fingerprint'] contains full anonymized data
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
        def apply_privacy(env)
          original_ip = env['REMOTE_ADDR']

          Otto.logger.debug "[IPPrivacyMiddleware] Original IP: #{original_ip}" if Otto.debug

          # Skip masking for private/localhost IPs unless explicitly configured to mask them
          # This provides better DX for development while still protecting public IPs
          unless @config.mask_private_ips
            if Otto::Privacy::IPPrivacy.private_or_localhost?(original_ip)
              # Keep original IP unchanged for localhost/private addresses
              env['otto.original_ip'] = original_ip
              Otto.logger.debug "[IPPrivacyMiddleware] Private/localhost IP exempted: #{original_ip}" if Otto.debug
              return
            end
          end

          # Create privacy-safe fingerprint
          fingerprint = Otto::Privacy::RedactedFingerprint.new(env, @config)

          # Set privacy-safe values in environment
          env['otto.redacted_fingerprint'] = fingerprint
          env['otto.masked_ip'] = fingerprint.masked_ip
          env['otto.hashed_ip'] = fingerprint.hashed_ip
          env['otto.geo_country'] = fingerprint.country

          # CRITICAL: Override REMOTE_ADDR with masked version
          # This ensures downstream code (rate limiting, auth, logging)
          # automatically uses the masked IP without modification
          env['REMOTE_ADDR'] = fingerprint.masked_ip

          Otto.logger.debug "[IPPrivacyMiddleware] Masked IP: #{fingerprint.masked_ip}" if Otto.debug

          # NOTE: We deliberately DO NOT set env['otto.original_ip']
          # This prevents accidental leakage of the real IP address
        end

        # Apply no-privacy settings (privacy explicitly disabled)
        #
        # When privacy is disabled, original IP is available for
        # backward compatibility with code that requires it.
        #
        # @param env [Hash] Rack environment
        def apply_no_privacy(env)
          # Store original IP for explicit access
          env['otto.original_ip'] = env['REMOTE_ADDR'].dup.force_encoding('UTF-8')

          # env['REMOTE_ADDR'] remains unchanged (real IP)
          # No fingerprint is created when privacy is disabled
        end
      end
    end
  end
end
