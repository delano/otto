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
      #   # env['otto.private_fingerprint'] contains full anonymized data
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

          # Skip masking for private/localhost IPs (development convenience)
          #
          # TODO: There should be a way for implementing projects to opt-in
          # for IP addresses match `private_or_localhost?`. By default we
          # don't privatize them b/c they do'nt have the same PII issues
          # and if we did it would be really annoying DX to figure out
          # what is going on. So just commenting out for now in lieu
          # to make sure we can see the privatization at work in
          # CommonLogger output.
          #
          # if Otto::Privacy::IPPrivacy.private_or_localhost?(original_ip)
          #   # Keep original IP unchanged for localhost/private addresses
          #   env['otto.original_ip'] = original_ip
          #   return
          # end

          # Create privacy-safe fingerprint
          fingerprint = Otto::Privacy::PrivateFingerprint.new(env, @config)

          # Set privacy-safe values in environment
          env['otto.private_fingerprint'] = fingerprint
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
