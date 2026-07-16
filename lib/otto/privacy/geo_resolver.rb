# lib/otto/privacy/geo_resolver.rb
#
# frozen_string_literal: true

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
    # 4. Local MMDB lookup, masked before lookup (Config#geo_db_reader)
    # 5. '**' (unknown)
    #
    # Steps 1 and 2 are SKIPPED when the request's geo headers are not trusted
    # (a non-trusted-proxy request while trusted proxies are configured) — every
    # geo header is client-spoofable unless you are actually behind that CDN.
    #
    # Resolution is HONEST: when no header, custom resolver, or database resolves
    # a country, the answer is '**' (unknown). Otto does not guess from a
    # hardcoded IP-range table — configure a database or an edge header for real
    # geo-location.
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
    # @example Resolve without any header, resolver, or database
    #   GeoResolver.resolve('8.8.8.8', {})
    #   # => '**' (unknown — Otto does not guess)
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
    #     def self.check_geo_database(ip, config)
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
    #                   └─ Miss → Unknown ('**')
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
      # 4. Local MMDB lookup (+config.geo_db_reader+), masked before lookup
      # 5. '**' for unknown (no guessing)
      #
      # Country-level MMDB networks are almost always >= /24, so a /24-masked
      # +x.y.z.0+ resolves to the same country as the real IP. The database
      # lookup masks internally, and the Otto middleware additionally hands this
      # method a masked IP and a masked env, so neither the database nor a custom
      # resolver ever sees the unmasked address.
      #
      # @param ip [String] IP address to resolve. When called from the Otto
      #   middleware this is already the masked IP; the database lookup masks
      #   again internally, so a direct caller passing a real IP still never
      #   exposes the unmasked address to the database.
      # @param env [Hash] Rack environment (may contain geo headers). In the
      #   framework path this is a masked view (REMOTE_ADDR/forwarded headers
      #   masked), so a custom resolver never sees the raw IP through env either.
      # @param config [Otto::Privacy::Config, nil] privacy config supplying the
      #   configured header and MMDB reader. When nil, only the built-in provider
      #   headers and the custom resolver are consulted.
      # @param headers_trusted [Boolean] whether request geo headers may be
      #   trusted for this request (default true; the middleware computes this
      #   from the trusted-proxy decision).
      # @return [String] ISO 3166-1 alpha-2 country code or '**'
      def self.resolve(ip, env = {}, config = nil, headers_trusted: true)
        return UNKNOWN if ip.nil? || ip.empty?

        # Resolution is honest: when no header, custom resolver, or database
        # resolves a country, the answer is '**' (unknown) — never a guess.
        resolve_from_sources(ip, env, config, headers_trusted) || UNKNOWN
      end

      # Walk the ordered resolution sources and return the first country found.
      #
      # @return [String, nil] country code, or nil if no source resolved
      # @api private
      def self.resolve_from_sources(ip, env, config, headers_trusted)
        if headers_trusted
          # 1. Configured header wins over 2. built-in provider headers.
          country = check_configured_header(env, config) || check_geo_headers(env)
          return country if country
        end

        # 3. Custom resolver hook, then 4. local MMDB lookup.
        check_custom_resolver(ip, env) || check_geo_database(ip, config)
      end
      private_class_method :resolve_from_sources

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

      # Invoke the configured custom resolver, guarding against errors.
      #
      # @param ip [String] IP address handed to the resolver (masked in the
      #   framework path — see {.resolve})
      # @param env [Hash] Rack environment (masked view in the framework path)
      # @return [String, nil] a valid country code, or nil
      # @api private
      def self.check_custom_resolver(ip, env)
        resolver = @custom_resolver
        return nil unless resolver

        country = resolver.call(ip, env)
        country if country && valid_country_code?(country)
      rescue StandardError => e
        # A custom resolver must never crash a request; fall through.
        warn "GeoResolver custom resolver error: #{e.message}" if $DEBUG
        nil
      end
      private_class_method :check_custom_resolver

      # Look up the country for an IP in the configured MMDB database.
      #
      # No-op (returns nil) when no config or reader is available. The IP is
      # masked (with the config's octet precision) before the lookup so the
      # unmasked address never reaches the database; masking is idempotent, so
      # an already-masked IP is unaffected. Country-level networks are >= /24,
      # so a /24-masked address resolves to the same country as the real one.
      #
      # The reader is any object responding to +#get(ip)+; result shapes from
      # both GeoLite2-Country-compatible ('country' => {'iso_code' => ...}) and
      # flat ('country_code' => ...) mmdb builds are handled.
      #
      # @param ip [String] IP address (masked internally before lookup)
      # @param config [Otto::Privacy::Config, nil]
      # @return [String, nil] valid country code, or nil on miss/error
      # @api private
      def self.check_geo_database(ip, config)
        reader = config&.geo_db_reader
        return nil unless reader

        lookup_ip = IPPrivacy.mask_ip(ip, config.octet_precision) || ip
        country = extract_db_country(reader.get(lookup_ip))
        valid_country_code?(country) ? country : nil
      rescue StandardError => e
        # A DB read must never crash a request; fall through.
        warn "GeoResolver database lookup error: #{e.message}" if $DEBUG
        nil
      end
      private_class_method :check_geo_database

      # Extract an ISO country code from an MMDB lookup result.
      #
      # Handles the shapes country databases actually use: GeoLite2-Country
      # style ('country' => {'iso_code' => 'US'}), the flat 'country_code' =>
      # 'US', and a bare 'country' => 'US'. The nested case is checked with an
      # explicit Hash guard rather than Hash#dig so a bare-String 'country'
      # value does not raise (String has no #dig).
      #
      # @param result [Object] whatever the reader returned for the IP
      # @return [String, nil] country code string, or nil
      # @api private
      def self.extract_db_country(result)
        return nil unless result.is_a?(Hash)

        country = result['country']
        code =
          if country.is_a?(Hash)
            country['iso_code']
          else
            result['country_code'] || country
          end
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
      # Simple provider headers whose value is the country code directly, checked
      # ahead of Akamai (whose value is a compound Edgescape string). Cloudflare
      # first (most widely deployed), then AWS CloudFront, then Fastly.
      PRIMARY_COUNTRY_HEADERS = %w[
        HTTP_CF_IPCOUNTRY
        HTTP_CLOUDFRONT_VIEWER_COUNTRY
        HTTP_FASTLY_CLIENT_IP_COUNTRY
      ].freeze

      # Remaining direct country-code headers, checked after Akamai: Azure Front
      # Door, Vercel, then the least-reliable semi-standard headers.
      SECONDARY_COUNTRY_HEADERS = %w[
        HTTP_X_AZURE_CLIENTIP_COUNTRY
        HTTP_X_VERCEL_IP_COUNTRY
        HTTP_X_GEO_COUNTRY
        HTTP_X_COUNTRY_CODE
        HTTP_COUNTRY_CODE
      ].freeze

      # Check CDN/infrastructure provider geo headers, in priority order:
      # Cloudflare, AWS CloudFront, Fastly, Akamai, Azure, Vercel, then the
      # semi-standard headers.
      #
      # @param env [Hash] Rack environment
      # @return [String, nil] ISO 3166-1 alpha-2 country code or nil
      # @api private
      def self.check_geo_headers(env)
        first_valid_country(env, PRIMARY_COUNTRY_HEADERS) ||
          akamai_country(env) ||
          first_valid_country(env, SECONDARY_COUNTRY_HEADERS)
      end
      private_class_method :check_geo_headers

      # First valid country code among the given env header keys, or nil.
      #
      # @param env [Hash] Rack environment
      # @param keys [Array<String>] env keys to check in order
      # @return [String, nil]
      # @api private
      def self.first_valid_country(env, keys)
        keys.each do |key|
          country = env[key]
          return country if valid_country_code?(country)
        end
        nil
      end
      private_class_method :first_valid_country

      # Country code from the Akamai Edgescape header, if present and valid.
      #
      # @param env [Hash] Rack environment
      # @return [String, nil]
      # @api private
      def self.akamai_country(env)
        edgescape = env['HTTP_X_AKAMAI_EDGESCAPE']
        return nil unless edgescape

        country = extract_akamai_country(edgescape)
        valid_country_code?(country) ? country : nil
      end
      private_class_method :akamai_country

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
