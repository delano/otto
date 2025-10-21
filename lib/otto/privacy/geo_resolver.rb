# lib/otto/privacy/geo_resolver.rb

require 'ipaddr'

class Otto
  module Privacy
    # Lightweight geo-location resolution for IP addresses
    #
    # Provides country-level geo-location without requiring external
    # databases or API calls. Supports headers from major CDN/infrastructure
    # providers (Cloudflare, AWS CloudFront, Fastly, Akamai, Azure) with
    # fallback to basic IP range detection.
    #
    # Supported CDN/Infrastructure Headers:
    # - Cloudflare: CF-IPCountry
    # - AWS CloudFront: CloudFront-Viewer-Country
    # - Fastly: Fastly-Client-IP-Country
    # - Akamai: X-Akamai-Edgescape (country_code=XX format)
    # - Azure Front Door: X-Azure-ClientIP-Country
    # - Semi-standard: X-Geo-Country, X-Country-Code, Country-Code
    #
    # @example Resolve country from Cloudflare header
    #   env = { 'HTTP_CF_IPCOUNTRY' => 'US' }
    #   GeoResolver.resolve('1.2.3.4', env)
    #   # => 'US'
    #
    # @example Resolve from AWS CloudFront
    #   env = { 'HTTP_CLOUDFRONT_VIEWER_COUNTRY' => 'GB' }
    #   GeoResolver.resolve('1.2.3.4', env)
    #   # => 'GB'
    #
    # @example Resolve without CDN headers
    #   GeoResolver.resolve('9.9.9.9', {})
    #   # => 'CH' (Quad9 in Switzerland)
    #
    class GeoResolver
      # Unknown country code (not ISO 3166-1 alpha-2, intentionally distinct)
      UNKNOWN = '**'

      # Resolve country code for an IP address
      #
      # Resolution priority:
      # 1. CDN/infrastructure provider headers (Cloudflare, AWS, Fastly, etc.)
      # 2. Basic IP range detection for major countries/providers
      # 3. Return '**' for unknown
      #
      # @param ip [String] IP address to resolve
      # @param env [Hash] Rack environment (may contain geo headers)
      # @return [String] ISO 3166-1 alpha-2 country code or '**'
      def self.resolve(ip, env = {})
        return UNKNOWN if ip.nil? || ip.empty?

        # Check CDN/infrastructure headers in priority order
        # Priority based on reliability and deployment frequency
        country = check_geo_headers(env)
        return country if country

        # Fallback: Basic range detection
        detect_by_range(ip)
      rescue IPAddr::InvalidAddressError
        UNKNOWN
      end

      # Check CDN/infrastructure provider geo headers
      #
      # Headers are checked in order of reliability and deployment frequency:
      # 1. Cloudflare (CF-IPCountry) - Most widely deployed
      # 2. AWS CloudFront (CloudFront-Viewer-Country)
      # 3. Fastly (Fastly-Client-IP-Country)
      # 4. Akamai (X-Akamai-Edgescape) - Complex format, extract country
      # 5. Azure Front Door (X-Azure-ClientIP-Country)
      # 6. Semi-standard headers (X-Geo-Country, X-Country-Code, Country-Code)
      #
      # @param env [Hash] Rack environment
      # @return [String, nil] ISO 3166-1 alpha-2 country code or nil
      # @api private
      def self.check_geo_headers(env)
        # Cloudflare (most common)
        country = env['HTTP_CF_IPCOUNTRY']
        return country if valid_country_code?(country)

        # AWS CloudFront
        country = env['HTTP_CLOUDFRONT_VIEWER_COUNTRY']
        return country if valid_country_code?(country)

        # Fastly
        country = env['HTTP_FASTLY_CLIENT_IP_COUNTRY']
        return country if valid_country_code?(country)

        # Akamai Edgescape (format: country_code=US,region_code=CA,...)
        if (edgescape = env['HTTP_X_AKAMAI_EDGESCAPE'])
          country = extract_akamai_country(edgescape)
          return country if valid_country_code?(country)
        end

        # Azure Front Door
        country = env['HTTP_X_AZURE_CLIENTIP_COUNTRY']
        return country if valid_country_code?(country)

        # Semi-standard headers (least reliable, check last)
        country = env['HTTP_X_GEO_COUNTRY']
        return country if valid_country_code?(country)

        country = env['HTTP_X_COUNTRY_CODE']
        return country if valid_country_code?(country)

        country = env['HTTP_COUNTRY_CODE']
        return country if valid_country_code?(country)

        nil
      end
      private_class_method :check_geo_headers

      # Extract country code from Akamai Edgescape header
      #
      # Edgescape format: "country_code=US,region_code=CA,city=LOSANGELES,..."
      #
      # @param edgescape [String] Akamai Edgescape header value
      # @return [String, nil] Country code or nil
      # @api private
      def self.extract_akamai_country(edgescape)
        return nil unless edgescape.is_a?(String)

        # Extract country_code=XX (must be exactly 2 uppercase letters, bounded)
        # Use word boundary or comma to ensure we don't match partial strings like "INVALID"
        match = edgescape.match(/country_code=([A-Z]{2})(?:,|\z)/)
        match ? match[1] : nil
      end
      private_class_method :extract_akamai_country

      # Detect country by IP range (basic implementation)
      #
      # Detects major cloud providers and well-known IP ranges.
      # This is intentionally limited - for comprehensive geo-location,
      # use CloudFlare or a dedicated GeoIP database.
      #
      # @param ip [String] IP address
      # @return [String] Country code or '**'
      # @api private
      def self.detect_by_range(ip)
        addr = IPAddr.new(ip)

        # Private/local addresses
        return UNKNOWN if IPPrivacy.private_or_localhost?(ip)

        # Check against known ranges
        KNOWN_RANGES.each do |range, country|
          return country if range.include?(addr)
        end

        UNKNOWN
      end
      private_class_method :detect_by_range

      # Validate country code format
      #
      # @param code [String] Country code to validate
      # @return [Boolean] true if valid ISO 3166-1 alpha-2 code
      # @api private
      def self.valid_country_code?(code)
        code.is_a?(String) && code.length == 2 && code.match?(/^[A-Z]{2}$/)
      end
      private_class_method :valid_country_code?

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
