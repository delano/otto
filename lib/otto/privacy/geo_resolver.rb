# frozen_string_literal: true

require 'ipaddr'

class Otto
  module Privacy
    # Lightweight geo-location resolution for IP addresses
    #
    # Provides country-level geo-location without requiring external
    # databases or API calls. Uses CloudFlare headers when available,
    # with fallback to basic IP range detection.
    #
    # @example Resolve country from CloudFlare header
    #   env = { 'HTTP_CF_IPCOUNTRY' => 'US' }
    #   GeoResolver.resolve('1.2.3.4', env)
    #   # => 'US'
    #
    # @example Resolve without CloudFlare
    #   GeoResolver.resolve('8.8.8.8', {})
    #   # => 'US' (Google DNS detected as US)
    #
    class GeoResolver
      # Unknown country code (ISO 3166-1 alpha-2)
      UNKNOWN = 'XX'

      # Resolve country code for an IP address
      #
      # Resolution priority:
      # 1. CloudFlare CF-IPCountry header (most reliable)
      # 2. Basic IP range detection for major countries/providers
      # 3. Return 'XX' for unknown
      #
      # @param ip [String] IP address to resolve
      # @param env [Hash] Rack environment (may contain CF headers)
      # @return [String] ISO 3166-1 alpha-2 country code or 'XX'
      def self.resolve(ip, env = {})
        return UNKNOWN if ip.nil? || ip.empty?

        # Priority 1: CloudFlare header (free, accurate, no database)
        cf_country = env['HTTP_CF_IPCOUNTRY']
        return cf_country if cf_country && valid_country_code?(cf_country)

        # Priority 2: Basic range detection
        detect_by_range(ip)
      rescue IPAddr::InvalidAddressError
        UNKNOWN
      end

      # Detect country by IP range (basic implementation)
      #
      # Detects major cloud providers and well-known IP ranges.
      # This is intentionally limited - for comprehensive geo-location,
      # use CloudFlare or a dedicated GeoIP database.
      #
      # @param ip [String] IP address
      # @return [String] Country code or 'XX'
      # @api private
      def self.detect_by_range(ip)
        addr = IPAddr.new(ip)

        # Private/local addresses
        return UNKNOWN if private_or_local?(addr)

        # Check against known ranges
        KNOWN_RANGES.each do |range, country|
          return country if range.include?(addr)
        end

        UNKNOWN
      end
      private_class_method :detect_by_range

      # Check if IP is private or local
      #
      # @param addr [IPAddr] IP address object
      # @return [Boolean] true if private or local
      # @api private
      def self.private_or_local?(addr)
        # RFC 1918 private ranges
        PRIVATE_RANGES.any? { |range| range.include?(addr) }
      end
      private_class_method :private_or_local?

      # Validate country code format
      #
      # @param code [String] Country code to validate
      # @return [Boolean] true if valid ISO 3166-1 alpha-2 code
      # @api private
      def self.valid_country_code?(code)
        code.is_a?(String) && code.length == 2 && code.match?(/^[A-Z]{2}$/)
      end
      private_class_method :valid_country_code?

      # Private IP ranges (RFC 1918 + loopback + link-local)
      PRIVATE_RANGES = [
        IPAddr.new('10.0.0.0/8'),        # Private
        IPAddr.new('172.16.0.0/12'),     # Private
        IPAddr.new('192.168.0.0/16'),    # Private
        IPAddr.new('127.0.0.0/8'),       # Loopback
        IPAddr.new('169.254.0.0/16'),    # Link-local
        IPAddr.new('::1/128'),           # IPv6 loopback
        IPAddr.new('fe80::/10'),         # IPv6 link-local
        IPAddr.new('fc00::/7'),          # IPv6 private
      ].freeze

      # Known IP ranges for major providers (limited set for basic detection)
      # For comprehensive geo-location, use CloudFlare or GeoIP database
      KNOWN_RANGES = {
        # Google Public DNS
        IPAddr.new('8.8.8.0/24') => 'US',
        IPAddr.new('8.8.4.0/24') => 'US',

        # Cloudflare DNS
        IPAddr.new('1.1.1.0/24') => 'US',
        IPAddr.new('1.0.0.0/24') => 'US',

        # AWS US-East
        IPAddr.new('52.0.0.0/11') => 'US',
        IPAddr.new('54.0.0.0/8') => 'US',

        # AWS EU-West
        IPAddr.new('34.240.0.0/13') => 'IE',
        IPAddr.new('52.16.0.0/14') => 'IE',

        # AWS AP-Southeast
        IPAddr.new('13.210.0.0/15') => 'AU',
        IPAddr.new('52.62.0.0/15') => 'AU',

        # Quad9 DNS (Switzerland)
        IPAddr.new('9.9.9.0/24') => 'CH',

        # OpenDNS
        IPAddr.new('208.67.222.0/24') => 'US',
        IPAddr.new('208.67.220.0/24') => 'US',
      }.freeze
    end
  end
end
