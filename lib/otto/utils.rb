# lib/otto/utils.rb
#
# frozen_string_literal: true

require 'ipaddr'

class Otto
  # Utility methods for common operations and helpers
  module Utils
    extend self

    # Forwarded-for style headers consulted (in order) when resolving the real
    # client IP from behind a trusted proxy. Shared by IPPrivacyMiddleware and
    # Otto::Request so the two resolvers cannot drift.
    FORWARDED_FOR_HEADERS = %w[
      HTTP_X_FORWARDED_FOR
      HTTP_X_REAL_IP
      HTTP_X_CLIENT_IP
    ].freeze

    # Special-use IPv4/IPv6 ranges that IPAddr's #private?/#loopback?/#link_local?
    # predicates do not cover but that should still be treated as non-public
    # (e.g. when picking the real client out of a forwarded chain).
    SPECIAL_USE_RANGES = [
      IPAddr.new('0.0.0.0/8'),   # "this" network / unspecified (IPv4)
      IPAddr.new('224.0.0.0/4'), # IPv4 multicast
      IPAddr.new('::/128'),      # IPv6 unspecified
      IPAddr.new('ff00::/8'),    # IPv6 multicast
    ].freeze

    # @return [Time] Current time in UTC
    def now
      Time.now.utc
    end

    # Returns the current time in microseconds.
    # This is used to measure the duration of Database commands.
    #
    # Alias: now_in_microseconds
    #
    # @return [Integer] The current time in microseconds.
    def now_in_μs
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
    end
    alias now_in_microseconds now_in_μs

    # Determine if a value represents a "yes" or true value
    #
    # @param value [Object] The value to evaluate
    # @return [Boolean] True if the value represents "yes", false otherwise
    #
    # Examples:
    # yes?('true')  # => true
    # yes?('yes')   # => true
    # yes?('1')     # => true
    def yes?(value)
      !value.to_s.empty? && %w[true yes 1].include?(value.to_s.downcase)
    end

    # Validate and normalize an IP address (IPv4 and IPv6).
    #
    # Strips an optional port (IPv6-safe), validates with IPAddr, and returns
    # the cleaned address string, or nil if the input is blank or malformed.
    #
    # @param ip [String, nil] candidate address, optionally with a port
    # @return [String, nil] cleaned IP string, or nil if invalid
    def normalize_ip(ip)
      return nil if ip.nil? || ip.empty?

      candidate = strip_ip_port(ip.strip)
      return nil if candidate.nil? || candidate.empty?

      # IPAddr validates both IPv4 and IPv6; raises for malformed input
      IPAddr.new(candidate)
      candidate
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      nil
    end

    # Strip an optional port without corrupting IPv6 addresses.
    #
    # Handles bracketed IPv6 with a port (`[2001:db8::1]:443`) and IPv4
    # host:port (`203.0.113.5:443`). A bare IPv6 address (multiple colons,
    # no brackets) is returned unchanged.
    #
    # @param ip [String] candidate address, possibly including a port
    # @return [String] address with any port removed
    def strip_ip_port(ip)
      if ip.start_with?('[')
        inner = ip[/\A\[([^\]]+)\]/, 1]
        return inner if inner
      end

      return ip.split(':', 2).first if ip.count(':') == 1

      ip
    end

    # Resolve the real client IP from a Rack env, honoring forwarded headers
    # only when the connecting peer (REMOTE_ADDR) is a trusted proxy.
    #
    # This is the single canonical resolver shared by IPPrivacyMiddleware
    # ("resolve once") and Otto::Request#client_ipaddress (its no-middleware
    # fallback), so both paths agree on which headers to trust and how to walk
    # a proxy chain. It walks the forwarded chain left-to-right and returns the
    # first address that is not itself a trusted proxy; if the peer is not a
    # trusted proxy (or there is no config) it returns REMOTE_ADDR unchanged.
    #
    # @param env [Hash] Rack environment
    # @param security_config [Otto::Security::Config, nil] config exposing #trusted_proxy?
    # @return [String, nil] resolved client IP (the raw REMOTE_ADDR when no proxy applies)
    def resolve_client_ip(env, security_config)
      remote_addr = env['REMOTE_ADDR']

      # No config, or the peer is a direct (untrusted) connection: REMOTE_ADDR
      # is the client. Don't honor forwarded headers from untrusted sources.
      return remote_addr unless security_config&.trusted_proxy?(remote_addr)

      forwarded_ips = FORWARDED_FOR_HEADERS
                      .filter_map { |header| env[header] }
                      .flat_map { |value| value.split(/,\s*/) }

      forwarded_ips.each do |candidate|
        clean_ip = normalize_ip(candidate.strip)
        next unless clean_ip

        # First address in the chain that isn't a known proxy is the client.
        return clean_ip unless security_config.trusted_proxy?(clean_ip)
      end

      # Whole chain was trusted proxies (or empty): fall back to the peer.
      remote_addr
    end

    # Whether an address is non-public: RFC1918 private, loopback, link-local,
    # multicast, or unspecified — for both IPv4 and IPv6.
    #
    # Uses IPAddr's family-aware predicates (which also fold IPv4-mapped IPv6
    # via #native) plus an explicit set of special-use ranges that the
    # predicates don't cover (IPv4 0.0.0.0/8 and 224.0.0.0/4, IPv6 ::/128 and
    # ff00::/8). Returns false for malformed input rather than raising.
    #
    # @param ip [String, IPAddr, nil] address to classify
    # @return [Boolean]
    def private_ip?(ip)
      return false if ip.nil?
      return false if ip.respond_to?(:empty?) && ip.empty?

      addr = ip.is_a?(IPAddr) ? ip : IPAddr.new(strip_ip_port(ip.to_s.strip))
      addr = addr.native # fold IPv4-mapped IPv6 (::ffff:a.b.c.d) to IPv4

      return true if addr.private? || addr.loopback? || addr.link_local?

      SPECIAL_USE_RANGES.any? { |range| range.family == addr.family && range.include?(addr) }
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      false
    end
  end
end
