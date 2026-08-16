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
      #
      # @example Declare the observability posture for a compliance deployment
      #   otto.configure_ip_privacy(profile: :audit)
      #
      # @param profile [Symbol] Named privacy profile (:anonymous, :masked, or
      #   :audit) applied FIRST as a preset over disabled/mask_private_ips, so
      #   any other option in the same call overrides it. This declares the
      #   deployment's observability posture in one reviewable word; see
      #   Otto::Privacy::Config::PROFILES.
      #
      # rubocop:disable Metrics/ParameterLists -- a keyword-only configuration
      # method; the options are self-documenting at the call site and grouping
      # them into a hash would only obscure the supported settings.
      def configure_ip_privacy(octet_precision: nil, hash_rotation: nil, geo: nil, redis: nil,
                               correlation_secret: nil, geo_header: nil, geo_db_path: nil,
                               geo_db_reader: nil, profile: nil, asn: nil, asn_db_path: nil,
                               asn_db_reader: nil, anonymizer: nil, anonymizer_db_path: nil,
                               anonymizer_db_reader: nil)
        # rubocop:enable Metrics/ParameterLists
        ensure_not_frozen!
        config = @security_config.ip_privacy_config

        # Geo headers are honored only for peers matching enumerated CIDR
        # matchers, never for count-trusted hops, so a geo_header configured
        # alongside depth mode could never be consulted. Fail loud here
        # (depth-then-geo order; the trusted_proxy_depth= setter catches
        # geo-then-depth). A blank geo_header canonicalizes to nil ("clear"),
        # which stays legal under depth.
        if Otto::Privacy::Config.canonicalize_geo_header(geo_header) &&
           @security_config.trusted_proxy_depth_mode?
          raise ArgumentError, Otto::Security::Config::GEO_HEADER_DEPTH_CONFLICT_MESSAGE
        end
        knobs = { profile: profile, octet_precision: octet_precision,
                  hash_rotation: hash_rotation, geo: geo,
                  correlation_secret: correlation_secret, redis: redis }

        # Dry-run the assignments on a throwaway copy and validate the combined
        # result there, so a rejected knob (octet_precision: 7 after a profile
        # preset, say) raises before the live config has been touched — the
        # call is all-or-nothing, never half-applied.
        apply_privacy_knobs(config.dup, knobs).validate!
        apply_privacy_knobs(config, knobs)

        apply_geo_config(config, geo: geo, geo_header: geo_header,
                                 geo_db_path: geo_db_path, geo_db_reader: geo_db_reader)
        apply_enrichment_signal(config, :asn, asn, asn_db_path, asn_db_reader)
        apply_enrichment_signal(config, :anonymizer, anonymizer, anonymizer_db_path, anonymizer_db_reader)
      end

      private

      # Assign the non-geo privacy knobs onto a config.
      #
      # Every kwarg uses a nil guard: nil means "leave unchanged", any other
      # value — including false or "" — is a real assignment that must either
      # take effect or fail validation loudly. A truthiness guard would
      # silently drop false (and, for correlation_secret, the explicit ""
      # that disables the correlation hash).
      #
      # @param config [Otto::Privacy::Config] the config to mutate
      # @param knobs [Hash] the non-geo keyword arguments from configure_ip_privacy
      # @return [Otto::Privacy::Config] the same config, for chaining
      # @api private
      def apply_privacy_knobs(config, knobs)
        config.profile = knobs[:profile] unless knobs[:profile].nil?
        config.octet_precision = knobs[:octet_precision] unless knobs[:octet_precision].nil?
        config.hash_rotation_period = knobs[:hash_rotation] unless knobs[:hash_rotation].nil?
        config.geo_enabled = knobs[:geo] unless knobs[:geo].nil?
        config.correlation_secret = knobs[:correlation_secret] unless knobs[:correlation_secret].nil?
        config.instance_variable_set(:@redis, knobs[:redis]) unless knobs[:redis].nil?
        config
      end

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

        # A newly supplied reader or path replaces the other database source. A
        # reader given in this call wins over a path (documented precedence); a
        # path given on its own clears any prior injected reader so it actually
        # takes effect — otherwise the stale override would silently shadow the
        # new path (leaving lookups pointed at a closed/old reader).
        if !geo_db_reader.nil?
          config.geo_db_reader = geo_db_reader
          config.geo_db_path = geo_db_path unless geo_db_path.nil?
        elsif !geo_db_path.nil?
          config.geo_db_reader = nil
          config.geo_db_path = geo_db_path
        end

        config.load_geo_database! if geo_touched
      end

      # Apply one opt-in enrichment signal (ASN or anonymizer classification).
      #
      # Same contract as {#apply_geo_config}: nil means "leave unchanged", a
      # reader supplied in this call wins over a path, and a path supplied on
      # its own clears any prior injected reader so it actually takes effect.
      # Any touched knob triggers a boot-time (re)load so a bad path fails
      # here, not on the first request that needs a lookup.
      #
      # These deliberately live outside apply_privacy_knobs. That runs twice —
      # once against a shallow config.dup for the dry-run validation — and a
      # dup shares reader ivars with the original, so loading a database there
      # would touch live state during what is supposed to be a rehearsal.
      #
      # @param config [Otto::Privacy::Config] the privacy config to mutate
      # @param prefix [Symbol] :asn or :anonymizer, selecting the config members
      # @api private
      def apply_enrichment_signal(config, prefix, enabled, path, reader)
        config.public_send(:"#{prefix}_enabled=", enabled) unless enabled.nil?
        apply_db_source(config, prefix, path, reader)
        config.public_send(:"load_#{prefix}_database!") if [enabled, path, reader].any? { |v| !v.nil? }
      end

      # Reader-vs-path precedence for one enrichment signal, mirroring the geo
      # branch in {#apply_geo_config}.
      #
      # @api private
      def apply_db_source(config, prefix, path, reader)
        if !reader.nil?
          config.public_send(:"#{prefix}_db_reader=", reader)
          config.public_send(:"#{prefix}_db_path=", path) unless path.nil?
        elsif !path.nil?
          config.public_send(:"#{prefix}_db_reader=", nil)
          config.public_send(:"#{prefix}_db_path=", path)
        end
      end
    end
  end
end
