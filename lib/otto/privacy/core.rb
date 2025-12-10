# lib/otto/privacy/core.rb
#
# frozen_string_literal: true

class Otto
  module Privacy
    # Core privacy configuration methods included in the Otto class.
    # Provides the public API for configuring IP privacy features.
    module Core
      # Disable IP privacy to access original IP addresses
      #
      # IMPORTANT: By default, Otto masks public IP addresses for privacy.
      # Private/localhost IPs (127.0.0.0/8, 10.0.0.0/8, etc.) are never masked.
      # Only disable this if you need access to original public IPs.
      #
      # When disabled:
      # - env['REMOTE_ADDR'] contains the real IP address
      # - env['otto.original_ip'] also contains the real IP
      # - No PrivateFingerprint is created
      #
      # @example
      #   otto.disable_ip_privacy!
      def disable_ip_privacy!
        ensure_not_frozen!
        @security_config.ip_privacy_config.disable!
      end

      # Enable full IP privacy (mask ALL IPs including private/localhost)
      #
      # By default, Otto exempts private and localhost IPs from masking for
      # better development experience. Call this method to mask ALL IPs
      # regardless of type.
      #
      # @example Enable full privacy (mask all IPs)
      #   otto = Otto.new(routes_file)
      #   otto.enable_full_ip_privacy!
      #   # Now 127.0.0.1 → 127.0.0.0, 192.168.1.100 → 192.168.1.0
      #
      # @return [void]
      # @raise [FrozenError] if called after configuration is frozen
      def enable_full_ip_privacy!
        ensure_not_frozen!
        @security_config.ip_privacy_config.mask_private_ips = true
      end

      # Configure IP privacy settings
      #
      # Privacy is enabled by default. Use this method to customize privacy
      # behavior without disabling it entirely.
      #
      # @param octet_precision [Integer] Number of octets to mask (1 or 2, default: 1)
      # @param hash_rotation [Integer] Seconds between key rotation (default: 86400)
      # @param geo [Boolean] Enable geo-location resolution (default: true)
      # @param redis [Redis] Redis connection for multi-server atomic key generation
      #
      # @example Mask 2 octets instead of 1
      #   otto.configure_ip_privacy(octet_precision: 2)
      #
      # @example Disable geo-location
      #   otto.configure_ip_privacy(geo: false)
      #
      # @example Custom hash rotation
      #   otto.configure_ip_privacy(hash_rotation: 24.hours)
      #
      # @example Multi-server with Redis
      #   redis = Redis.new(url: ENV['REDIS_URL'])
      #   otto.configure_ip_privacy(redis: redis)
      def configure_ip_privacy(octet_precision: nil, hash_rotation: nil, geo: nil, redis: nil)
        ensure_not_frozen!
        config = @security_config.ip_privacy_config

        config.octet_precision = octet_precision if octet_precision
        config.hash_rotation_period = hash_rotation if hash_rotation
        config.geo_enabled = geo unless geo.nil?
        config.instance_variable_set(:@redis, redis) if redis

        # Validate configuration
        config.validate!
      end
    end
  end
end
