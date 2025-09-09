# lib/concurrent_cache_store.rb

require 'concurrent-ruby'

# Thread-safe cache store with TTL support for Rack::Attack
# Provides ActiveSupport::Cache::MemoryStore-compatible interface
#
# Usage:
#
#   Rack::Attack.cache.store = ConcurrentCacheStore.new(default_ttl: 300)
#
class ConcurrentCacheStore
  # @param default_ttl [Integer] Default time-to-live in seconds for cache entries
  def initialize(default_ttl: 300)
    @store       = Concurrent::Map.new
    @default_ttl = default_ttl
  end

  # Retrieves a value from the cache
  # @param key [String] The cache key
  # @return [Object, nil] The cached value or nil if expired/missing
  def read(key)
    entry = @store[key]
    return nil unless entry

    if Time.now > entry[:expires_at]
      @store.delete(key)
      nil
    else
      entry[:value]
    end
  end

  # Stores a value in the cache with expiration
  # @param key [String] The cache key
  # @param value [Object] The value to store
  # @param expires_in [Integer] TTL in seconds (optional)
  # @return [Object] The stored value
  def write(key, value, expires_in: @default_ttl)
    @store[key] = {
      value: value,
      expires_at: Time.now + expires_in,
    }
    value
  end

  # Atomically increments a numeric value, creating if missing
  # @param key [String] The cache key
  # @param amount [Integer] Amount to increment by
  # @param expires_in [Integer] TTL in seconds for new entries
  # @return [Integer] The new value after increment
  def increment(key, amount = 1, expires_in: @default_ttl)
    @store.compute(key) do |_, entry|
      if entry && Time.now <= entry[:expires_at]
        entry[:value] += amount
        entry
      else
        { value: amount, expires_at: Time.now + expires_in }
      end
    end[:value]
  end

  # Removes all entries from the cache
  # @return [void]
  def clear
    @store.clear
  end
end
