# frozen_string_literal: true

require 'ipaddr'
require 'securerandom'
require 'digest'

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
    #   config.mask_level = 2  # Mask 2 octets instead of 1
    #
    class Config
      attr_accessor :mask_level, :hash_rotation_period, :geo_enabled
      attr_reader :disabled

      # Initialize privacy configuration
      #
      # @param options [Hash] Configuration options
      # @option options [Integer] :mask_level Number of octets to mask (1 or 2, default: 1)
      # @option options [Integer] :hash_rotation_period Seconds between key rotation (default: 86400)
      # @option options [Boolean] :geo_enabled Enable geo-location resolution (default: true)
      # @option options [Boolean] :disabled Disable privacy entirely (default: false)
      # @option options [Redis] :redis Optional Redis connection for multi-server environments
      def initialize(options = {})
        @mask_level = options.fetch(:mask_level, 1)
        @hash_rotation_period = options.fetch(:hash_rotation_period, 86_400) # 24 hours
        @geo_enabled = options.fetch(:geo_enabled, true)
        @disabled = options.fetch(:disabled, false)  # Enabled by default (privacy-by-default)
        @redis = options[:redis]  # Optional Redis connection for multi-server environments
        # Thread-safe hash for rotation keys - initialized lazily (fallback if no Redis)
        @rotation_keys = nil
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
        unless [1, 2].include?(@mask_level)
          raise ArgumentError, "mask_level must be 1 or 2, got: #{@mask_level}"
        end

        if @hash_rotation_period < 60
          raise ArgumentError, "hash_rotation_period must be at least 60 seconds"
        end
      end

      private

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
        ttl = (@hash_rotation_period * 1.2).to_i  # Auto-cleanup with 20% buffer

        key = SecureRandom.hex(32)

        # SET NX GET returns old value if key exists, nil if we set it
        existing_key = @redis.set(redis_key, key, nx: true, get: true, ex: ttl)

        existing_key || key
      end

      # In-memory rotation key (single-server fallback)
      #
      # Uses Concurrent::Hash for thread-safety within a single process.
      # NOT atomic across multiple servers.
      #
      # @return [String] Current rotation key
      # @api private
      def rotation_key_memory
        # Lazy initialization of thread-safe hash
        require 'concurrent' unless defined?(Concurrent::Hash)
        @rotation_keys ||= Concurrent::Hash.new

        now_seconds = Time.now.utc.to_i

        # Quantize to rotation period boundary (e.g., midnight UTC for 24-hour period)
        seconds_since_epoch = now_seconds % @hash_rotation_period
        rotation_timestamp = now_seconds - seconds_since_epoch

        # Atomically get or create key for this rotation period
        # Concurrent::Hash doesn't have fetch_or_store, so we use [] with ||=
        @rotation_keys[rotation_timestamp] ||= begin
          @rotation_keys.clear if @rotation_keys.size > 1  # Discard old keys
          SecureRandom.hex(32)
        end
      end

    end
  end
end
