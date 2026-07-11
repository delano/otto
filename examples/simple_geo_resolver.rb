#!/usr/bin/env ruby
# frozen_string_literal: true

# Otto GeoResolver Guide
#
# GeoResolver resolves an ISO country code, first hit wins:
#   1. configured header (geo_header)  2. provider headers (Cloudflare, Vercel,
#   ...)  3. custom_resolver  4. local MMDB database (geo_db_path)  5. '**'
#
# This guide covers the extension points: a configured header, a custom
# resolver, and the local MMDB database. See docs/geo-country.md for the full
# reference (trust gating, config, data files).

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
  else nil # nil = continue with the remaining resolution steps
  end
end

# Step 2: Set it globally
Otto::Privacy::GeoResolver.custom_resolver = custom_resolver

# Step 3: Test it
puts "1.2.3.4 -> #{Otto::Privacy::GeoResolver.resolve('1.2.3.4', {})}"
puts "8.8.8.8 -> #{Otto::Privacy::GeoResolver.resolve('8.8.8.8', {})} (no match -> '**')"

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
# Configured header + local MMDB database (the built-in extension points)
# =============================================================================

puts "\nConfigured header and local MMDB database"
puts '-' * 40

# An application-trusted header outranks the built-in provider headers. Give
# either the HTTP name or the CGI env key; Otto canonicalizes it.
Otto::Privacy::GeoResolver.geo_header = 'X-Client-Country'
env = { 'HTTP_X_CLIENT_COUNTRY' => 'PT', 'HTTP_CF_IPCOUNTRY' => 'US' }
puts "configured header wins -> #{Otto::Privacy::GeoResolver.resolve('1.2.3.4', env)}"
Otto::Privacy::GeoResolver.geo_header = nil

# The local MMDB fallback needs the optional `maxmind-db` gem and a country
# database on disk (see docs/geo-country.md and examples/update_geo_database.rb).
# Enable it via configure_ip_privacy so a bad path fails fast at boot:
#
#   otto.configure_ip_privacy(geo_db_path: 'data/geo-whois-asn-country.mmdb')
#   Otto::Privacy::GeoResolver.resolve('8.8.8.0', {})  # => 'US' (masked IP)
#
# `geo: false` short-circuits geo entirely and unloads any database from memory.

# =============================================================================
# Performance Tips
# =============================================================================

puts "\nPerformance Tips"
puts '-' * 40

puts '• Cache API results to avoid repeated calls'
puts '• Return nil from a custom resolver to fall through to the MMDB database'
puts '• Prefer CDN/provider headers when available (fastest, no lookup)'
puts '• Load the MMDB once at boot (MODE_MEMORY); refresh the datafile out-of-band'

puts "\nProduction Pattern: Valkey/Redis Bloom Filters"
puts '-' * 40
puts 'For high-traffic applications, consider Bloom/Cuckoo filters:'
puts '• Store RIR IP prefixes in Valkey/Redis Bloom filter per country'
puts '• Memory: ~1MB for entire IPv4 table at 1% false positive rate'
puts '• Lookup: O(1) microsecond-level performance via BF.EXISTS'
puts '• Zero external dependencies, rebuild nightly from public RIR files'
puts '• Perfect for CDN header fallback when requests bypass edge'
puts ''
