# lib/otto/utils.rb
#
# frozen_string_literal: true

require 'ipaddr'

class Otto
  # Utility methods for common operations and helpers
  module Utils
    extend self

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
  end
end
