#!/usr/bin/env ruby
# frozen_string_literal: true

# Otto GeoResolver Extension Guide
#
# This guide shows two approaches to extend Otto's IP geolocation:
# 1. Configuration-based (simple, inline)
# 2. Subclass-based (full control)

require 'bundler/setup'
require 'otto'

# =============================================================================
# Quick Start: Configuration-based Extension
# =============================================================================

puts 'Simple Custom Geo Resolution'
puts '-' * 40

# Step 1: Define your resolver function
custom_resolver = lambda do |ip, _env|
  case ip
  when '1.2.3.4' then 'US'
  when '5.6.7.8' then 'GB'
  else nil # nil = use Otto's built-in resolver
  end
end

# Step 2: Set it globally
Otto::Privacy::GeoResolver.custom_resolver = custom_resolver

# Step 3: Test it
puts "1.2.3.4 -> #{Otto::Privacy::GeoResolver.resolve('1.2.3.4', {})}"
puts "8.8.8.8 -> #{Otto::Privacy::GeoResolver.resolve('8.8.8.8', {})} (fallback)"

# Reset for next example
Otto::Privacy::GeoResolver.custom_resolver = nil

# =============================================================================
# Real-World Example: API Integration with Caching
# =============================================================================

puts "\nAPI Integration with Caching"
puts '-' * 40

class CachedGeoAPI
  def initialize(api_key)
    @api_key = api_key
    @cache = {}
  end

  def call(ip, _env)
    # Return cached result if available
    return @cache[ip] if @cache.key?(ip)

    # Simulate API call (replace with real HTTP request)
    country = mock_api_call(ip)

    # Cache the result
    @cache[ip] = country
    country
  rescue StandardError => e
    puts "API failed: #{e.message}"
    nil # Fallback to Otto's resolver
  end

  private

  def mock_api_call(ip)
    # Replace this with: HTTP.get("https://api.example.com/geo?ip=#{ip}")
    case ip
    when /^1\./ then 'US'
    when /^2\./ then 'GB'
    end
  end
end

# Use the cached API resolver
api_resolver = CachedGeoAPI.new('your_api_key')
Otto::Privacy::GeoResolver.custom_resolver = api_resolver

puts "1.2.3.4 -> #{Otto::Privacy::GeoResolver.resolve('1.2.3.4', {})}"
puts "1.2.3.4 -> #{Otto::Privacy::GeoResolver.resolve('1.2.3.4', {})} (cached)"

Otto::Privacy::GeoResolver.custom_resolver = nil

# =============================================================================
# Performance Tips
# =============================================================================

puts "\nPerformance Tips"
puts '-' * 40

puts '• Cache API results to avoid repeated calls'
puts "• Return nil from custom resolver to use Otto's fast fallback"
puts '• Use CloudFlare headers when available (fastest)'
puts '• Consider async/background geo updates for heavy traffic'

puts "\nProduction Pattern: Valkey/Redis Bloom Filters"
puts '-' * 40
puts 'For high-traffic applications, consider Bloom/Cuckoo filters:'
puts '• Store RIR IP prefixes in Valkey/Redis Bloom filter per country'
puts '• Memory: ~1MB for entire IPv4 table at 1% false positive rate'
puts '• Lookup: O(1) microsecond-level performance via BF.EXISTS'
puts '• Zero external dependencies, rebuild nightly from public RIR files'
puts '• Perfect for CDN header fallback when requests bypass edge'
puts ''
