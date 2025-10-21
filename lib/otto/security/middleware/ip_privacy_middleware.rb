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
        # Apply privacy settings to environment
        #
        # @param env [Hash] Rack environment
        # Apply privacy settings to environment
        #
        # @param env [Hash] Rack environment
        def apply_privacy(env)
          # Resolve the actual client IP (handling proxies)
          client_ip = resolve_client_ip(env)

          Otto.logger.debug "[IPPrivacyMiddleware] Resolved client IP: #{client_ip}" if Otto.debug

          # Skip masking for private/localhost IPs unless explicitly configured to mask them
          # This provides better DX for development while still protecting public IPs
          unless @config.mask_private_ips
            if Otto::Privacy::IPPrivacy.private_or_localhost?(client_ip)
              # Update REMOTE_ADDR to the resolved client IP (even though it's not masked)
              env['REMOTE_ADDR'] = client_ip
              env['otto.original_ip'] = client_ip
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

          # Replace User-Agent with anonymized version (consistent with IP masking)
          if fingerprint.anonymized_ua
            env['HTTP_USER_AGENT'] = fingerprint.anonymized_ua
          end

          # Replace Referer with anonymized version (query params stripped)
          if fingerprint.referer
            env['HTTP_REFERER'] = fingerprint.referer
          end

          # Mask X-Forwarded-For headers to prevent leakage
          # Replace with masked IP so proxy resolution logic finds the masked IP
          mask_forwarded_headers(env, fingerprint.masked_ip)

          Otto.logger.debug "[IPPrivacyMiddleware] Masked IP: #{fingerprint.masked_ip}" if Otto.debug

          # NOTE: We deliberately DO NOT set env['otto.original_ip'], env['otto.original_user_agent'],
          # or env['otto.original_referer']. This prevents accidental leakage of the real values.
        end


        # Resolve the actual client IP address from the request
        #
        # This method handles proxy scenarios by checking X-Forwarded-For and
        # other proxy headers from trusted proxies, similar to Rack's logic
        # and Otto's client_ipaddress method.
        #
        # @param env [Hash] Rack environment
        # @return [String] Resolved client IP address
        def resolve_client_ip(env)
          remote_addr = env['REMOTE_ADDR']

          # If we don't have a security config, use direct connection
          return remote_addr unless @security_config

          # If REMOTE_ADDR is not from a trusted proxy, it's the client IP
          return remote_addr unless trusted_proxy?(remote_addr)

          # REMOTE_ADDR is from a trusted proxy, check forwarded headers
          forwarded_ips = [
            env['HTTP_X_FORWARDED_FOR'],
            env['HTTP_X_REAL_IP'],
            env['HTTP_X_CLIENT_IP'],
          ].compact.map { |header| header.split(/,\s*/) }.flatten

          # Return the first valid public IP from forwarded headers
          forwarded_ips.each do |ip|
            clean_ip = validate_ip_address(ip.strip)
            next unless clean_ip

            # Return first IP that's not from a trusted proxy
            return clean_ip unless trusted_proxy?(clean_ip)
          end

          # Fallback to remote address if no valid forwarded IPs
          remote_addr
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

        # Validate and clean IP address
        #
        # @param ip [String, nil] IP address to validate
        # @return [String, nil] Cleaned IP or nil if invalid
        def validate_ip_address(ip)
          return nil if ip.nil? || ip.empty?

          # Remove any port number
          clean_ip = ip.split(':').first

          # Basic IPv4 format validation
          return nil unless clean_ip.match?(/\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/)

          # Validate each octet
          octets = clean_ip.split('.')
          return nil unless octets.all? { |octet| (0..255).cover?(octet.to_i) }

          clean_ip
        end

        # Apply no-privacy settings (privacy explicitly disabled)
        #
        # When privacy is disabled, original IP is available for
        # backward compatibility with code that requires it.
        #
        # @param env [Hash] Rack environment
        def apply_no_privacy(env)
          # Store original values for explicit access when privacy is disabled
          env['otto.original_ip'] = env['REMOTE_ADDR'].dup.force_encoding('UTF-8')

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
