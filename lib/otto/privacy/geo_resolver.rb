# lib/otto/privacy/geo_resolver.rb
#
# frozen_string_literal: true

require 'ipaddr'

class Otto
  module Privacy
    # Lightweight geo-location resolution for IP addresses
    #
    # Provides country-level geo-location. Headers from major CDN/infrastructure
    # providers are checked first; an optional local MaxMind-format (.mmdb)
    # database gives an offline fallback that operates on Otto's already-MASKED
    # IP (no external API calls, and the unmasked address never reaches the
    # resolver).
    #
    # Resolution order (first hit wins), when a privacy Config is supplied:
    # 1. App-configured trusted header (Config#geo_header), e.g. 'X-Client-Country'
    # 2. Built-in CDN/infrastructure provider headers (see below)
    # 3. Custom resolver hook ({.custom_resolver})
    # 4. Local MMDB lookup of the masked IP (Config#geo_db_reader)
    # 5. Built-in IP-range detection (a tiny best-effort table)
    # 6. '**' (unknown)
    #
    # Steps 1 and 2 are SKIPPED when the request's geo headers are not trusted
    # (a non-trusted-proxy request while trusted proxies are configured) — every
    # geo header is client-spoofable unless you are actually behind that CDN.
    #
    # Supported CDN/Infrastructure Headers:
    # - Cloudflare: CF-IPCountry
    # - AWS CloudFront: CloudFront-Viewer-Country
    # - Fastly: Fastly-Client-IP-Country
    # - Akamai: X-Akamai-Edgescape (country_code=XX format)
    # - Azure Front Door: X-Azure-ClientIP-Country
    # - Vercel: X-Vercel-IP-Country
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
    #   GeoResolver.resolve('8.8.8.8', {})
    #   # => 'US' (Google DNS via range detection)
    #
    # @example Using a custom resolver (MaxMind)
    #   GeoResolver.custom_resolver = ->(ip, env) {
    #     reader = MaxMind::DB.new('GeoLite2-Country.mmdb')
    #     result = reader.get(ip)
    #     result&.dig('country', 'iso_code')
    #   }
    #   GeoResolver.resolve('1.2.3.4', {})  # Uses custom resolver
    #
    # @example Extending via subclass
    #   class MyGeoResolver < Otto::Privacy::GeoResolver
    #     def self.detect_by_range(ip)
    #       # Custom logic here
    #       super  # Fall back to parent
    #     end
    #   end
    #
    #
    # Resolution flow
    #
    #    Request → Headers trusted?
    #              ├─ Yes → Config#geo_header set & valid? → Return country
    #              │        └─ Provider header present & valid? → Return country
    #              └─ (headers skipped when not trusted)
    #                 → Custom Resolver configured?
    #                   ├─ Valid → Return country
    #                   └─ Invalid/Error → Continue
    #                 → Local MMDB reader configured?
    #                   ├─ Hit → Return country
    #                   └─ Miss → Built-in range detection
    #                             └─ Unknown ('**')
    #
    class GeoResolver
      # Unknown country code (not ISO 3166-1 alpha-2, intentionally distinct)
      UNKNOWN = '**'

      # Custom resolver for extending geo-location capabilities
      # Can be set to a proc/lambda or a class responding to .call(ip, env)
      #
      # @example Using a proc
      #   GeoResolver.custom_resolver = ->(ip, env) {
      #     return nil  # Return nil to continue with built-in resolution
      #     # or return 'US' to provide custom country code
      #   }
      #
      # @example Using MaxMind
      #   GeoResolver.custom_resolver = ->(ip, env) {
      #     reader = MaxMind::DB.new('path/to/GeoLite2-Country.mmdb')
      #     result = reader.get(ip)
      #     result&.dig('country', 'iso_code')
      #   }
      #
      # Thread Safety Model:
      # This follows Ruby's standard configuration pattern:
      # - Set ONCE at boot time (single-threaded initialization)
      # - Read many times during requests (multi-threaded reads)
      # - No synchronization needed for this access pattern
      #
      # Runtime resolver switching is NOT supported. Changing the resolver
      # while processing requests creates race conditions (write vs read).
      # This is intentional - resolver configuration is boot-time only.
      @custom_resolver = nil

      class << self
        attr_accessor :custom_resolver

        # Set a custom resolver for geo-location
        #
        # MUST be called during single-threaded initialization (before
        # accepting requests). Runtime changes while serving requests
        # will cause race conditions.
        #
        # @param resolver [Proc, #call] A proc or callable object that takes (ip, env)
        #   and returns a country code string or nil
        # @raise [ArgumentError] if resolver doesn't respond to :call
        def custom_resolver=(resolver)
          unless resolver.nil? || resolver.respond_to?(:call)
            raise ArgumentError, 'Custom resolver must respond to :call'
          end
          @custom_resolver = resolver
        end
      end

      # Resolve country code for an IP address.
      #
      # Resolution order (first hit wins). Header steps (1–2) are skipped when
      # +headers_trusted+ is false, since geo headers are client-spoofable
      # unless the request actually arrived through the trusted CDN/proxy:
      # 1. App-configured trusted header (+config.geo_header+)
      # 2. Built-in CDN/infrastructure provider headers
      # 3. Custom resolver hook ({.custom_resolver})
      # 4. Local MMDB lookup (+config.geo_db_reader+) — expects a MASKED IP
      # 5. Built-in IP-range detection
      # 6. '**' for unknown
      #
      # +ip+ SHOULD be the privacy-masked address when called from the Otto
      # middleware: country-level MMDB networks are almost always >= /24, so the
      # /24-masked +x.y.z.0+ resolves to the same country as the real IP, and the
      # unmasked address never reaches the resolver.
      #
      # @param ip [String] IP address to resolve (masked, in the framework path)
      # @param env [Hash] Rack environment (may contain geo headers)
      # @param config [Otto::Privacy::Config, nil] privacy config supplying the
      #   configured header and MMDB reader. When nil, only the built-in provider
      #   headers, custom resolver and range detection are used (legacy behavior).
      # @param headers_trusted [Boolean] whether request geo headers may be
      #   trusted for this request (default true; the middleware computes this
      #   from the trusted-proxy decision).
      # @return [String] ISO 3166-1 alpha-2 country code or '**'
      def self.resolve(ip, env = {}, config = nil, headers_trusted: true)
        return UNKNOWN if ip.nil? || ip.empty?

        if headers_trusted
          # 1. App-configured trusted header wins over provider headers.
          country = check_configured_header(env, config)
          return country if country

          # 2. Built-in CDN/infrastructure headers, in priority order.
          country = check_geo_headers(env)
          return country if country
        end

        # 3. Custom resolver hook, if configured.
        if @custom_resolver
          begin
            country = @custom_resolver.call(ip, env)
            return country if country && valid_country_code?(country)
          rescue StandardError => e
            # Log error but don't crash - fall through to built-in detection
            warn "GeoResolver custom resolver error: #{e.message}" if $DEBUG
          end
        end

        # 4. Local MMDB database lookup on the (masked) IP.
        country = check_geo_database(ip, config)
        return country if country

        # 5. Fallback: Basic range detection.
        detect_by_range(ip)
      rescue IPAddr::InvalidAddressError
        UNKNOWN
      end

      # Check the app-configured trusted geo header, if any.
      #
      # @param env [Hash] Rack environment
      # @param config [Otto::Privacy::Config, nil]
      # @return [String, nil] valid country code from the configured header, or nil
      # @api private
      def self.check_configured_header(env, config)
        header = config&.geo_header
        return nil unless header

        country = env[header]
        valid_country_code?(country) ? country : nil
      end
      private_class_method :check_configured_header

      # Look up the country for an IP in the configured MMDB database.
      #
      # No-op (returns nil) when no config or reader is available. The reader is
      # any object responding to +#get(ip)+; result shapes from both
      # GeoLite2-Country-compatible ('country' => {'iso_code' => ...}) and flat
      # ('country_code' => ...) mmdb builds are handled.
      #
      # @param ip [String] IP address (masked, in the framework path)
      # @param config [Otto::Privacy::Config, nil]
      # @return [String, nil] valid country code, or nil on miss/error
      # @api private
      def self.check_geo_database(ip, config)
        reader = config&.geo_db_reader
        return nil unless reader

        country = extract_db_country(reader.get(ip))
        valid_country_code?(country) ? country : nil
      rescue StandardError => e
        # A DB read must never crash a request; fall through to range detection.
        warn "GeoResolver database lookup error: #{e.message}" if $DEBUG
        nil
      end
      private_class_method :check_geo_database

      # Extract an ISO country code from an MMDB lookup result.
      #
      # @param result [Object] whatever the reader returned for the IP
      # @return [String, nil] country code string, or nil
      # @api private
      def self.extract_db_country(result)
        return nil unless result.is_a?(Hash)

        code = result.dig('country', 'iso_code') ||
               result['country_code'] ||
               result['country']
        code.is_a?(String) ? code : nil
      end
      private_class_method :extract_db_country

      # Check CDN/infrastructure provider geo headers
      #
      # Headers are checked in order of reliability and deployment frequency:
      # 1. Cloudflare (CF-IPCountry) - Most widely deployed
      # 2. AWS CloudFront (CloudFront-Viewer-Country)
      # 3. Fastly (Fastly-Client-IP-Country)
      # 4. Akamai (X-Akamai-Edgescape) - Complex format, extract country
      # 5. Azure Front Door (X-Azure-ClientIP-Country)
      # 6. Vercel (X-Vercel-IP-Country)
      # 7. Semi-standard headers (X-Geo-Country, X-Country-Code, Country-Code)
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

        # Vercel
        country = env['HTTP_X_VERCEL_IP_COUNTRY']
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
      # use CDN headers or configure a custom resolver.
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

      # Known IP ranges for major providers (limited set for basic detection)
      # For comprehensive geo-location, use CDN headers or custom resolver
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

      # Validate country code format
      #
      # @param code [String] Country code to validate
      # @return [Boolean] true if valid ISO 3166-1 alpha-2 code
      # @api private
      def self.valid_country_code?(code)
        code.is_a?(String) && code.length == 2 && code.match?(/^[A-Z]{2}$/)
      end
      private_class_method :valid_country_code?
    end
  end
end
