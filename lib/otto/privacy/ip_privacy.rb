# lib/otto/privacy/ip_privacy.rb

require 'ipaddr'
require 'digest'
require 'openssl'
require 'socket'

class Otto
  module Privacy
    # IP address anonymization utilities
    #
    # Provides methods for masking and hashing IP addresses to enhance
    # privacy while maintaining the ability to track sessions and analyze
    # traffic patterns.
    #
    # @example Mask an IPv4 address (1 octet)
    #   IPPrivacy.mask_ip('192.168.1.100', 1)
    #   # => '192.168.1.0'
    #
    # @example Mask an IPv4 address (2 octets)
    #   IPPrivacy.mask_ip('192.168.1.100', 2)
    #   # => '192.168.0.0'
    #
    # @example Hash an IP for session correlation
    #   key = 'daily-rotation-key'
    #   IPPrivacy.hash_ip('192.168.1.100', key)
    #   # => 'a3f8b2...' (consistent for same IP+key, changes when key rotates)
    #
    # @note All methods return UTF-8 encoded strings for Rack compatibility.
    #   See file:docs/ipaddr-encoding-quirk.md for details on IPAddr#to_s behavior.
    #
    class IPPrivacy
      # Mask an IP address by zeroing out the specified number of octets/bits
      #
      # For IPv4:
      # - octet_precision=1: Masks last octet (e.g., 192.168.1.100 → 192.168.1.0)
      # - octet_precision=2: Masks last 2 octets (e.g., 192.168.1.100 → 192.168.0.0)
      #
      # For IPv6:
      # - octet_precision=1: Masks last 80 bits
      # - octet_precision=2: Masks last 96 bits
      #
      # @param ip [String] IP address to mask
      # @param octet_precision [Integer] Number of trailing octets to mask (1 or 2, default: 1)
      # @return [String] Masked IP address (UTF-8 encoded)
      # @raise [ArgumentError] if IP is invalid or octet_precision is not 1 or 2
      def self.mask_ip(ip, octet_precision = 1)
        return nil if ip.nil? || ip.empty?

        raise ArgumentError, "octet_precision must be 1 or 2, got: #{octet_precision}" unless [1,
                                                                                               2].include?(octet_precision)

        begin
          addr = IPAddr.new(ip)

          if addr.ipv4?
            mask_ipv4(addr, octet_precision)
          else
            mask_ipv6(addr, octet_precision)
          end
        rescue IPAddr::InvalidAddressError => e
          raise ArgumentError, "Invalid IP address: #{ip} - #{e.message}"
        end
      end

      # Hash an IP address for session correlation without storing the original
      #
      # Uses HMAC-SHA256 with a daily-rotating key to create a consistent
      # identifier for the same IP within a key rotation period, but different
      # across rotations.
      #
      # @param ip [String] IP address to hash
      # @param key [String] Secret key for HMAC (should rotate daily)
      # @return [String] Hexadecimal hash string (64 characters)
      # @raise [ArgumentError] if IP or key is invalid
      def self.hash_ip(ip, key)
        return nil if ip.nil? || ip.empty?

        raise ArgumentError, 'Key cannot be nil or empty' if key.nil? || key.empty?

        # Normalize IP address format before hashing
        normalized_ip = begin
          IPAddr.new(ip).to_s
        rescue IPAddr::InvalidAddressError => e
          raise ArgumentError, "Invalid IP address: #{ip} - #{e.message}"
        end

        # Use HMAC-SHA256 for secure hashing with key
        OpenSSL::HMAC.hexdigest('SHA256', key, normalized_ip)
      end

      # Check if an IP address is valid
      #
      # @param ip [String] IP address to validate
      # @return [Boolean] true if valid IPv4 or IPv6 address
      def self.valid_ip?(ip)
        return false if ip.nil? || ip.empty?

        IPAddr.new(ip)
        true
      rescue IPAddr::InvalidAddressError
        false
      end

      # Check if an IP address is localhost or private (RFC 1918)
      #
      # Private/localhost IPs are not masked for development convenience.
      #
      # @param ip [String] IP address to check
      # @return [Boolean] true if IP is localhost or private
      def self.private_or_localhost?(ip)
        return false if ip.nil? || ip.empty?

        addr = IPAddr.new(ip)
        addr.private? || addr.loopback?
      rescue IPAddr::InvalidAddressError
        false
      end

      # Mask IPv4 address
      #
      # @param addr [IPAddr] IPAddr object (must be IPv4)
      # @param octet_precision [Integer] Number of trailing octets to mask (1 or 2)
      # @return [String] Masked IPv4 address (UTF-8 encoded)
      # @api private
      # @see file:docs/ipaddr-encoding-quirk.md IPAddr encoding behavior
      def self.mask_ipv4(addr, octet_precision)
        # Convert to integer for bitwise operations
        ip_int = addr.to_i

        # Create mask: 0xFFFFFFFF with trailing zeros
        # octet_precision=1: 0xFFFFFF00 (mask last 8 bits)
        # octet_precision=2: 0xFFFF0000 (mask last 16 bits)
        bits_to_mask = octet_precision * 8
        mask = (0xFFFFFFFF >> bits_to_mask) << bits_to_mask

        # Apply mask and convert back to IP
        masked_int = ip_int & mask

        # Force UTF-8 encoding: IPAddr#to_s returns US-ASCII for IPv4 but UTF-8
        # for IPv6. We normalize to UTF-8 for Rack compatibility and to prevent
        # Encoding::CompatibilityError. Safe because IP strings contain only
        # ASCII characters.
        # See also: https://github.com/ruby/ruby/blob/master/lib/ipaddr.rb
        IPAddr.new(masked_int, Socket::AF_INET).to_s.force_encoding('UTF-8')
      end
      private_class_method :mask_ipv4

      # Mask IPv6 address
      #
      # @param addr [IPAddr] IPAddr object (must be IPv6)
      # @param octet_precision [Integer] Number of trailing octets to mask (1 or 2)
      # @return [String] Masked IPv6 address (UTF-8 encoded)
      # @api private
      def self.mask_ipv6(addr, octet_precision)
        ip_int = addr.to_i

        # octet_precision=1: Mask last 80 bits (leave first 48 bits for network)
        # octet_precision=2: Mask last 96 bits (leave first 32 bits)
        bits_to_mask = octet_precision == 1 ? 80 : 96

        # Create mask by setting all 128 bits, then clearing the trailing bits we want to mask
        # Example: For bits_to_mask=80, this creates a mask with first 48 bits set to 1, last 80 bits set to 0
        # (1 << 128) - 1 creates 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF (all 128 bits set)
        mask = ((1 << 128) - 1) >> bits_to_mask << bits_to_mask

        masked_int = ip_int & mask

        IPAddr.new(masked_int, Socket::AF_INET6).to_s.force_encoding('UTF-8')
      end

      private_class_method :mask_ipv6
    end
  end
end
