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
      # @param geo [Boolean] Enable geo-location resolution (default: true). When
      #   false, geo short-circuits entirely: no headers are read and no database
      #   is loaded or consulted.
      # @param geo_header [String] Trusted, app-configured request header checked
      #   FIRST for the country code (e.g. 'X-Client-Country'). Accepts the HTTP
      #   or 'HTTP_*' CGI form; both canonicalize to the env key. Pass '' to clear.
      # @param geo_db_path [String] Path to a MaxMind-format (.mmdb) country
      #   database for the local IP->country fallback (looked up on the MASKED
      #   IP). Requires the optional 'maxmind-db' gem. A bad path raises at boot,
      #   not per-request. Pass '' to clear.
      # @param geo_db_reader [#get] Bring-your-own MMDB reader (any object
      #   responding to #get); overrides geo_db_path. Omitted/nil leaves any
      #   existing reader unchanged; use geo: false to stop consulting a database.
      # @param redis [Redis] Redis connection for multi-server atomic key generation
      # @param correlation_secret [String] A secret string that turns on IP
      #   correlation: it lets you tell whether two requests, even months apart,
      #   came from the same visitor — without your app ever seeing the real IP.
      #   (Otto masks the IP before your app runs; with a secret set it also
      #   fingerprints the full IP into req.ip_correlation_hash, which can't be
      #   reversed to an IP without the secret.) Omit it to leave any existing
      #   secret unchanged; pass an empty string to turn the feature back off.
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
      # @example Enable stable IP correlation (same visitor across days)
      #   otto.configure_ip_privacy(correlation_secret: ENV['IP_CORRELATION_SECRET'])
      #
      # @example Multi-server with Redis
      #   redis = Redis.new(url: ENV['REDIS_URL'])
      #   otto.configure_ip_privacy(redis: redis)
      def configure_ip_privacy(octet_precision: nil, hash_rotation: nil, geo: nil, redis: nil,
                               correlation_secret: nil, geo_header: nil, geo_db_path: nil,
                               geo_db_reader: nil)
        ensure_not_frozen!
        config = @security_config.ip_privacy_config

        config.octet_precision = octet_precision if octet_precision
        config.hash_rotation_period = hash_rotation if hash_rotation
        config.geo_enabled = geo unless geo.nil?
        # Mirror geo's `unless nil?` guard: nil means "leave unchanged", while an
        # explicit "" is a real value that disables the correlation hash. (A
        # plain `if correlation_secret` would also assign "" since "" is truthy
        # in Ruby, but stating the nil intent explicitly keeps this consistent
        # with the other nilable kwargs.)
        config.correlation_secret = correlation_secret unless correlation_secret.nil?
        config.instance_variable_set(:@redis, redis) if redis

        # Validate configuration
        config.validate!

        apply_geo_config(config, geo: geo, geo_header: geo_header,
                                 geo_db_path: geo_db_path, geo_db_reader: geo_db_reader)
      end

      private

      # Apply the geo-fallback settings and (re)load the database when needed.
      #
      # nil means "leave unchanged"; '' clears a header or path. Any geo-affecting
      # change triggers a boot-time (re)load so a bad geo_db_path fails here, not
      # on the first request that needs a lookup.
      #
      # @param config [Otto::Privacy::Config] the privacy config to mutate
      # @api private
      def apply_geo_config(config, geo:, geo_header:, geo_db_path:, geo_db_reader:)
        geo_touched = [geo, geo_header, geo_db_path, geo_db_reader].any? { |v| !v.nil? }

        config.geo_header = geo_header unless geo_header.nil?
        config.geo_db_reader = geo_db_reader unless geo_db_reader.nil?
        config.geo_db_path = geo_db_path unless geo_db_path.nil?

        config.load_geo_database! if geo_touched
      end
    end
  end
end
