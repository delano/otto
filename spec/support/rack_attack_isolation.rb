# spec/support/rack_attack_isolation.rb
#
# frozen_string_literal: true

# Rack::Attack keeps its throttles, its throttled responder, and its counter
# cache in PROCESS-GLOBAL state. Merely constructing an Otto rate-limit
# middleware calls configure_rack_attack!, which re-registers the global
# 'requests' / 'mcp_requests' / 'mcp_tool_calls' throttles with whatever limits
# that instance was built with — so a spec that builds an Otto with
# `requests_per_minute: 5` silently rewrites the limits every later spec sees.
# Combined with spec_helper's random ordering, that produces failures that only
# reproduce under one seed.
#
# Include this context in any spec that constructs rate-limiting middleware or
# calls configure_rack_attack! directly:
#
#   include_context 'with rack attack isolation'
#
# Minimal in-memory counter store for Rack::Attack.
#
# rack-attack has no store of its own: Cache.default_store only resolves to
# Rails.cache, and this gem depends on neither Rails nor ActiveSupport, so
# Rack::Attack.cache.store is nil here and no throttle can actually count.
# Assign one of these in any spec that needs a throttle to TRIP.
#
# Entries never expire — examples finish well inside a 60-second window, and
# the isolation context below empties the store around each one anyway.
class RackAttackTestStore
  def initialize
    @data = {}
  end

  def increment(key, amount = 1, expires_in: nil)
    _ = expires_in
    @data[key] = (@data[key] || 0) + amount
  end

  def read(key)
    @data[key]
  end

  def write(key, value, expires_in: nil)
    _ = expires_in
    @data[key] = value
  end

  def delete(key)
    @data.delete(key)
  end

  def clear
    @data.clear
  end
end

# It snapshots and restores the global configuration and empties the counter
# cache around each example, so throttle counts never leak either.
RSpec.shared_context 'with rack attack isolation' do
  around do |example|
    unless defined?(Rack::Attack)
      example.run
      next
    end

    throttles = Rack::Attack.throttles.dup
    responder = Rack::Attack.throttled_responder
    store     = Rack::Attack.cache.store

    clear_rack_attack_store = lambda do
      current = Rack::Attack.cache.store
      current.clear if current.respond_to?(:clear)
    end

    clear_rack_attack_store.call

    begin
      example.run
    ensure
      clear_rack_attack_store.call
      Rack::Attack.throttles.replace(throttles)
      Rack::Attack.throttled_responder = responder
      Rack::Attack.cache.store         = store
    end
  end
end
