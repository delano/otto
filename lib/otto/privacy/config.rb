# frozen_string_literal: true

require 'ipaddr'
require 'securerandom'
require 'digest'

class Otto
  module Privacy
    # Configuration for IP privacy features
    #
    # Privacy is enabled by default. IP addresses are automatically masked
    # unless explicitly disabled with Otto#disable_ip_privacy!
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
      def initialize(options = {})
        @mask_level = options.fetch(:mask_level, 1)
        @hash_rotation_period = options.fetch(:hash_rotation_period, 86_400) # 24 hours
        @geo_enabled = options.fetch(:geo_enabled, true)
        @disabled = options.fetch(:disabled, false)
        @daily_keys = {}
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

      # Get the current daily key for IP hashing
      #
      # Keys rotate based on hash_rotation_period (default: 24 hours).
      # Old keys are automatically cleaned up after 7 days.
      #
      # @return [String] Current daily key for hashing
      def daily_key
        now = Time.now.utc
        rotation_id = (now.to_i / @hash_rotation_period).to_i

        # Generate new key if needed
        @daily_keys[rotation_id] ||= SecureRandom.hex(32)

        # Clean up old keys (keep last 7 rotations)
        @daily_keys.select! { |id, _| id >= rotation_id - 6 }

        @daily_keys[rotation_id]
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
    end
  end
end
