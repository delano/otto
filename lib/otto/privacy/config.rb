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
      attr_reader :disabled, :correlation_secret

      # Class-level rotation key storage (mutable, not frozen with instances)
      # This is stored at the class level so it persists across frozen config instances
      @rotation_keys_store = nil

      class << self
        # Get the class-level rotation keys store
        # @return [Concurrent::Map] Thread-safe map for rotation keys
        def rotation_keys_store
          @rotation_keys_store = Concurrent::Map.new unless defined?(@rotation_keys_store) && @rotation_keys_store
          @rotation_keys_store
        end
      end

      # Initialize privacy configuration
      #
      # @param options [Hash] Configuration options
      # @option options [Integer] :octet_precision Number of trailing octets to mask (1 or 2, default: 1)
      # @option options [Integer] :hash_rotation_period Seconds between key rotation (default: 86400)
      # @option options [Boolean] :geo_enabled Enable geo-location resolution (default: true)
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
