# lib/otto/privacy/config.rb
#
# frozen_string_literal: true

require 'ipaddr'
require 'securerandom'
require 'digest'

require 'concurrent'

require_relative '../core/freezable'

class Otto
  module Privacy
    # Configuration for IP privacy features
    #
    # Privacy is ENABLED by default for public IPs. Private/localhost IPs are not masked.
    #
    # @example Default configuration (privacy enabled)
    #   config = Otto::Privacy::Config.new
    #   config.enabled? # => true
    #
    # @example Configure masking level
    #   config = Otto::Privacy::Config.new
    #   config.octet_precision = 2  # Mask 2 octets instead of 1
    #
    class Config
      include Otto::Core::Freezable

      attr_accessor :octet_precision, :hash_rotation_period, :geo_enabled, :mask_private_ips
      attr_reader :disabled, :correlation_secret, :geo_header, :geo_db_path

      # Class-level rotation key storage (mutable, not frozen with instances)
      # This is stored at the class level so it persists across frozen config instances
      @rotation_keys_store = nil

      # Class-level geo database (MMDB reader) storage.
      #
      # Held at the class level for the SAME reason as rotation_keys_store: a
      # Config instance is deep-frozen after the first request (see
      # Otto::Core::Freezable), and deep-freezing recurses into every instance
      # variable. An MMDB reader (e.g. MaxMind::DB in MODE_MEMORY) is a live
      # object whose #get may use internal buffers, so freezing it risks a
      # FrozenError per request. Keeping the reader here — and storing only a
      # String lookup key on the instance — keeps the frozen Config free of any
      # live reader reference. Keying by path also de-duplicates: the same mmdb
      # file is opened once and shared across Config instances.
      @geo_db_store = nil

      class << self
        # Get the class-level rotation keys store
        # @return [Concurrent::Map] Thread-safe map for rotation keys
        def rotation_keys_store
          @rotation_keys_store = Concurrent::Map.new unless defined?(@rotation_keys_store) && @rotation_keys_store
          @rotation_keys_store
        end

        # Get the class-level geo database store (key => MMDB reader).
        # @return [Concurrent::Map] Thread-safe map of readers
        def geo_db_store
          @geo_db_store = Concurrent::Map.new unless defined?(@geo_db_store) && @geo_db_store
          @geo_db_store
        end
      end

      # Initialize privacy configuration
      #
      # @param options [Hash] Configuration options
      # @option options [Integer] :octet_precision Number of trailing octets to mask (1 or 2, default: 1)
      # @option options [Integer] :hash_rotation_period Seconds between key rotation (default: 86400)
      # @option options [Boolean] :geo_enabled Enable geo-location resolution (default: true)
      # @option options [String] :geo_header Trusted, app-configured request header to read the
      #   country code from FIRST (before the built-in CDN provider headers). Accepts either
      #   the HTTP form ('X-Client-Country') or the Rack CGI form ('HTTP_X_CLIENT_COUNTRY');
      #   both canonicalize to the 'HTTP_*' env key. Default nil (no app-configured header).
      # @option options [String] :geo_db_path Filesystem path to a MaxMind-format (.mmdb)
      #   country database used as the local IP->country fallback (looked up on the already
      #   MASKED IP). Requires the 'maxmind-db' gem. A bad/unreadable path raises at boot,
      #   not per-request. Default nil (no local database fallback).
      # @option options [#get] :geo_db_reader Bring-your-own MMDB reader (any object responding
      #   to #get, e.g. a MaxMind::DB or a compatible reader). Overrides :geo_db_path when set,
      #   so the reader choice stays independent of Otto. Default nil.
      # @option options [Boolean] :disabled Disable privacy entirely (default: false)
      # @option options [Boolean] :mask_private_ips Mask private/localhost IPs (default: false)
      # @option options [String] :correlation_secret A secret string that turns
      #   on IP correlation. Default nil, meaning off.
      #
      #   It answers one question: "are these two requests, maybe months apart,
      #   from the same visitor?" — without your app ever seeing the real IP.
      #
      #   Otto masks each IP before your app runs (203.0.113.42 becomes
      #   203.0.113.0), which is too coarse to tell visitors apart. When a secret
      #   is set, Otto also fingerprints the full IP, before masking, and hands
      #   your app just the fingerprint as req.ip_correlation_hash. The same IP
      #   always produces the same fingerprint, and it can't be turned back into
      #   an IP without the secret.
      #
      #   Keep the secret stable — changing it changes every fingerprint. An empty
      #   string is rejected, because an empty secret would let anyone reverse the
      #   fingerprint back to an IP.
      # @option options [Redis] :redis Optional Redis connection for multi-server environments
      def initialize(options = {})
        @octet_precision = options.fetch(:octet_precision, 1)
        @hash_rotation_period = options.fetch(:hash_rotation_period, 86_400) # 24 hours
        @geo_enabled = options.fetch(:geo_enabled, true)
        @disabled = options.fetch(:disabled, false) # Enabled by default (privacy-by-default)
        @mask_private_ips = options.fetch(:mask_private_ips, false) # Don't mask private/localhost by default
        self.correlation_secret = options.fetch(:correlation_secret, nil) # Opt-in stable IP-correlation secret
        @redis = options[:redis] # Optional Redis connection for multi-server environments

        # Geo-location fallback configuration (all opt-in, boot-time only).
        @geo_db_key = nil # class-store lookup key for the effective MMDB reader
        @geo_db_override_key = nil # set when a reader is injected via geo_db_reader=
        self.geo_header = options[:geo_header] # canonicalized to an HTTP_* env key (or nil)
        self.geo_db_reader = options[:geo_db_reader] if options.key?(:geo_db_reader)
        @geo_db_path = normalize_geo_db_path(options[:geo_db_path])
        load_geo_database! # build/attach the reader now so a bad path fails at boot
      end

      # Set the stable correlation secret, validating its type up front.
      #
      # nil or an empty string mean "correlation hash disabled" (see
      # IPPrivacyMiddleware#correlation_hash — an empty key is never used to
      # hash). Any other non-String is a configuration error: without this
      # guard it would surface far from its cause, as a NoMethodError on
      # `#empty?` deep inside per-request middleware. Fail fast here instead,
      # at the point of misconfiguration, with a message that names the type.
      #
      # @param value [String, nil] stable secret, or nil/"" to disable
      # @raise [ArgumentError] if value is neither a String nor nil
      def correlation_secret=(value)
        unless value.nil? || value.is_a?(String)
          raise ArgumentError, "correlation_secret must be a String or nil, got: #{value.class}"
        end

        @correlation_secret = value
      end

      # Set the trusted, app-configured geo header.
      #
      # Canonicalizes to a Rack CGI env key ('HTTP_*'): 'X-Client-Country',
      # 'x-client-country' and 'HTTP_X_CLIENT_COUNTRY' all become
      # 'HTTP_X_CLIENT_COUNTRY'. nil / blank clears it. Rack 3's lowercase rule
      # applies to RESPONSE headers; request headers remain 'HTTP_*' env keys,
      # so this is the correct form to read from the request env.
      #
      # @param value [String, nil] header name in either HTTP or CGI form
      def geo_header=(value)
        @geo_header = self.class.canonicalize_geo_header(value)
      end

      # Set the geo database path (MMDB file) used for the local fallback.
      #
      # Does not build the reader on its own — call {#load_geo_database!} (which
      # {Otto::Privacy::Core#configure_ip_privacy} does for you) so a bad path
      # fails at boot rather than per-request.
      #
      # @param value [String, nil] filesystem path to a .mmdb file, or nil
      def geo_db_path=(value)
        @geo_db_path = normalize_geo_db_path(value)
      end

      # Inject a ready-made MMDB reader (any object responding to #get).
      #
      # This keeps the reader choice independent of Otto (MaxMind::DB, yhirose's
      # maxminddb, or a custom object all work) and is the seam used by tests.
      # When set, it takes precedence over {#geo_db_path}. Passing nil clears the
      # override. The reader is stored at the class level (never on this frozen-
      # able instance); only a lookup key is kept here.
      #
      # @param reader [#get, nil] MMDB-compatible reader, or nil to clear
      # @raise [ArgumentError] if reader does not respond to :get
      def geo_db_reader=(reader)
        if reader.nil?
          @geo_db_override_key = nil
          return
        end

        raise ArgumentError, "geo_db_reader must respond to :get, got: #{reader.class}" unless reader.respond_to?(:get)

        key = "reader:#{reader.object_id}"
        self.class.geo_db_store[key] = reader
        @geo_db_override_key = key
      end

      # The effective MMDB reader for this config, or nil.
      #
      # Returns nil when geo is disabled (so `geo: false` consults no database
      # even if one was previously configured) or when neither a reader override
      # nor a database path is set. Reads from the class-level store, so it is
      # safe to call on a frozen Config.
      #
      # @return [#get, nil] the reader, or nil
      def geo_db_reader
        return nil unless @geo_enabled
        return nil unless @geo_db_key

        self.class.geo_db_store[@geo_db_key]
      end

      # Build/attach the geo database reader for the current configuration.
      #
      # Boot-time only. Resolves the effective reader (injected override wins
      # over a path) and records its class-store key on this instance. A String
      # path is opened eagerly here so an unreadable path or a missing
      # 'maxmind-db' gem raises now, at configuration time, rather than on the
      # first request that needs a lookup. When geo is disabled, no database is
      # loaded and no key is retained.
      #
      # @return [void]
      # @raise [ArgumentError] if the path is unreadable or maxmind-db is absent
      def load_geo_database!
        @geo_db_key = nil
        return unless @geo_enabled

        if @geo_db_override_key
          @geo_db_key = @geo_db_override_key
        elsif @geo_db_path
          # compute_if_absent opens the file once per path across all Config
          # instances; a failure in the block propagates (nothing is cached),
          # so a bad path raises here at boot.
          self.class.geo_db_store.compute_if_absent(@geo_db_path) do
            build_maxmind_reader(@geo_db_path)
          end
          @geo_db_key = @geo_db_path
        end
      end

      # Canonicalize a geo header name to a Rack CGI env key ('HTTP_*').
      #
      # @param value [String, nil] header in HTTP ('X-Client-Country') or CGI form
      # @return [String, nil] 'HTTP_*' env key, or nil for nil/blank input
      def self.canonicalize_geo_header(value)
        return nil if value.nil?

        key = value.to_s.strip
        return nil if key.empty?

        key = key.upcase.tr('-', '_')
        key.start_with?('HTTP_') ? key : "HTTP_#{key}"
      end

      # Check if privacy is enabled
      #
      # @return [Boolean] true if privacy is enabled (default)
      def enabled?
        !@disabled
      end

      # Check if privacy is disabled
      #
      # @return [Boolean] true if privacy was explicitly disabled
      def disabled?
        @disabled
      end

      # Disable privacy (allows access to original IPs)
      #
      # IMPORTANT: This should only be used when you have a specific
      # requirement to access original IP addresses. By default, Otto
      # provides privacy-safe masked IPs.
      #
      # @return [self]
      def disable!
        @disabled = true
        self
      end

      # Enable privacy (default state)
      #
      # @return [self]
      def enable!
        @disabled = false
        self
      end

      # Get the current rotation key for IP hashing
      #
      # Keys rotate at fixed intervals based on hash_rotation_period (default: 24 hours).
      # Each rotation period gets a unique key, ensuring IP addresses hash differently
      # across periods while remaining consistent within.
      #
      # Multi-server support:
      # - With Redis: Uses SET NX GET EX for atomic key generation across all servers
      # - Without Redis: Falls back to in-memory Concurrent::Hash (single-server only)
      #
      # Redis keys:
      #   - rotation_key:{timestamp} - Stores the rotation key with TTL
      #
      # @return [String] Current rotation key for hashing
      def rotation_key
        if @redis
          rotation_key_redis
        else
          rotation_key_memory
        end
      end

      # Validate configuration settings
      #
      # @raise [ArgumentError] if configuration is invalid
      def validate!
        raise ArgumentError, "octet_precision must be 1 or 2, got: #{@octet_precision}" unless [1,
                                                                                                2].include?(@octet_precision)

        return unless @hash_rotation_period < 60

        raise ArgumentError, 'hash_rotation_period must be at least 60 seconds'
      end

      private

      # Normalize a geo_db_path option to a non-empty String or nil.
      #
      # @param value [String, nil] raw path option
      # @return [String, nil]
      def normalize_geo_db_path(value)
        return nil if value.nil?

        path = value.to_s.strip
        path.empty? ? nil : path
      end

      # Open an MMDB file into an in-memory reader, failing fast on problems.
      #
      # The 'maxmind-db' gem is an OPTIONAL dependency: it is required lazily
      # here, only when a database path is actually configured, so Otto stays
      # dependency-light for the (common) header-only geo setups. Callers who
      # prefer a different reader can inject one via {#geo_db_reader=} and never
      # trigger this path.
      #
      # @param path [String] filesystem path to a .mmdb file
      # @return [MaxMind::DB] in-memory reader
      # @raise [ArgumentError] if the path is unreadable or the gem is missing
      def build_maxmind_reader(path)
        raise ArgumentError, "geo_db_path is not readable: #{path.inspect}" unless File.readable?(path)

        begin
          require 'maxmind/db'
        rescue LoadError
          raise ArgumentError,
                "geo_db_path is set (#{path.inspect}) but the 'maxmind-db' gem is not available. " \
                "Add `gem 'maxmind-db'` to your Gemfile, or inject your own reader via " \
                'configure_ip_privacy(geo_db_reader: ...).'
        end

        begin
          MaxMind::DB.new(path, mode: MaxMind::DB::MODE_MEMORY)
        rescue StandardError => e
          raise ArgumentError, "Failed to open geo_db_path #{path.inspect}: #{e.class}: #{e.message}"
        end
      end

      # Redis-based rotation key (atomic across multiple servers)
      #
      # Uses SET NX GET EX to atomically:
      # 1. Check if key exists
      # 2. Set new key only if missing
      # 3. Return existing or newly set key
      # 4. Auto-expire with TTL
      #
      # @return [String] Current rotation key
      # @api private
      def rotation_key_redis
        now_seconds = Time.now.utc.to_i

        # Quantize to rotation period boundary
        rotation_timestamp = (now_seconds / @hash_rotation_period) * @hash_rotation_period

        redis_key = "rotation_key:#{rotation_timestamp}"
        ttl = (@hash_rotation_period * 1.2).to_i # Auto-cleanup with 20% buffer

        key = SecureRandom.hex(32)

        # SET NX GET returns old value if key exists, nil if we set it
        # @see https://valkey.io/commands/set/
        existing_key = @redis.set(redis_key, key, nx: true, get: true, ex: ttl)

        existing_key || key
      end

      # In-memory rotation key (single-server fallback)
      #
      # Uses class-level Concurrent::Hash for thread-safety within a single process.
      # NOT atomic across multiple servers.
      #
      # The rotation keys are stored at the class level so they remain mutable
      # even when config instances are frozen.
      #
      # @return [String] Current rotation key
      # @api private
      def rotation_key_memory
        rotation_keys = self.class.rotation_keys_store

        now_seconds = Time.now.utc.to_i

        # Quantize to rotation period boundary (e.g., midnight UTC for 24-hour period)
        seconds_since_epoch = now_seconds % @hash_rotation_period
        rotation_timestamp = now_seconds - seconds_since_epoch

        # Atomically get or create key for this rotation period
        # Use compute_if_absent for thread-safe atomic operation
        key = rotation_keys.compute_if_absent(rotation_timestamp) do
          # Generate new key atomically
          # IMPORTANT: Don't modify the map inside this block to avoid deadlock
          SecureRandom.hex(32)
        end

        # Clean up old keys after atomic operation completes
        # This runs outside compute_if_absent to avoid deadlock
        if rotation_keys.size > 1
          rotation_keys.each_key do |ts|
            rotation_keys.delete(ts) if ts != rotation_timestamp
          end
        end

        key
      end
    end
  end
end
