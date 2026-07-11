# lib/otto/privacy/geo_resolver.rb
#
# frozen_string_literal: true

require 'ipaddr'

class Otto
  module Privacy
    # Country-level geo-location resolution for IP addresses.
    #
    # Resolves an ISO 3166-1 alpha-2 country code from, in priority order:
    #
    #   1. An application-configured, trusted geo header ({.geo_header}).
    #   2. Known CDN/infrastructure provider headers (Cloudflare, AWS
    #      CloudFront, Fastly, Akamai, Azure, Vercel, and a few semi-standard
    #      names).
    #   3. A custom resolver hook ({.custom_resolver}).
    #   4. A local MaxMind-DB (MMDB) country database ({.geo_db_path}).
    #   5. The unknown sentinel {UNKNOWN} (`'**'`).
    #
    # Header trust (steps 1 and 2) is gated on whether the request arrived via
    # a trusted proxy: geo headers are trivially client-spoofable unless you
    # are actually behind the CDN that sets them. See {.resolve} and
    # {Otto::Security::Middleware::IPPrivacyMiddleware} for the
    # `otto.via_trusted_proxy` / `otto.trusted_proxies_configured` env facts
    # this reads.
    #
    # The database lookup (step 4) operates on whatever IP it is handed. In the
    # middleware path that is the *masked* IP (e.g. `203.0.113.0`), never the
    # real address — country-level MMDB networks are almost always ≥ /24, so the
    # /24-masked value resolves to the same country as the real IP. The `ip`
    # argument to {.resolve} is the masked value; a custom resolver should use
    # that argument rather than reading the raw address out of `env` (which, at
    # resolution time, may still carry pre-masking forwarded headers).
    #
    # == Configuration is boot-time only
    #
    # {.custom_resolver}, {.geo_header}, and {.geo_db_path} are process-global
    # and MUST be set during single-threaded initialization (before serving
    # requests), matching the {.custom_resolver} contract. Reads happen
    # concurrently across request threads; writes while serving requests are a
    # data race. Runtime resolver/DB swapping is intentionally unsupported.
    #
    # Typical setup goes through {Otto::Privacy::Core#configure_ip_privacy}:
    #
    #   otto.configure_ip_privacy(
    #     geo_header: 'X-Client-Country',                  # trusted app header (optional)
    #     geo_db_path: 'data/geo-whois-asn-country.mmdb',  # MMDB fallback (optional)
    #   )
    #
    # @example Resolve country from a Cloudflare header
    #   GeoResolver.resolve('1.2.3.4', { 'HTTP_CF_IPCOUNTRY' => 'US' })
    #   # => 'US'
    #
    # @example Local MMDB lookup (requires the `maxmind-db` gem)
    #   Otto::Privacy::GeoResolver.geo_db_path = 'data/geo-whois-asn-country.mmdb'
    #   GeoResolver.resolve('8.8.8.0', {})  # masked IP
    #   # => 'US'
    #
    # @example Using a custom resolver
    #   GeoResolver.custom_resolver = ->(ip, env) {
    #     MyGeoService.country_for(ip)  # return a 2-letter code or nil
    #   }
    #
    class GeoResolver
      # Unknown country code (not ISO 3166-1 alpha-2, intentionally distinct)
      UNKNOWN = '**'

      # Raised when {.geo_db_path=} is pointed at a database that cannot be
      # loaded (missing file, unreadable, not an MMDB, or the `maxmind-db` gem
      # is unavailable). Raised at configuration time so misconfiguration fails
      # at boot rather than silently per-request.
      class DatabaseError < StandardError; end

      # Custom resolver for extending geo-location capabilities.
      # A proc/lambda or any object responding to #call(ip, env) that returns
      # an ISO 3166-1 alpha-2 country code String, or nil to continue with the
      # remaining resolution steps.
      #
      # Thread Safety: set ONCE at boot (single-threaded init), read many times
      # during requests. No synchronization for this access pattern. Runtime
      # switching is NOT supported (write-vs-read race).
      @custom_resolver = nil

      # Application-configured trusted geo header, stored as its Rack CGI env
      # key (e.g. 'HTTP_X_CLIENT_COUNTRY'). See {.geo_header=}.
      @geo_header = nil

      # Path to the configured MMDB country database, or nil. See {.geo_db_path=}.
      @geo_db_path = nil

      # Loaded MMDB reader (responds to #get(ip)), or nil when no database is
      # configured/loaded. See {.database_reader=}.
      @database_reader = nil

      # Ordered provider geo headers (Rack CGI env keys), most reliable first,
      # split around the specially-parsed Akamai Edgescape header so its
      # priority slot (after Fastly, before Azure) is preserved.
      PRIMARY_PROVIDER_HEADERS = %w[
        HTTP_CF_IPCOUNTRY
        HTTP_CLOUDFRONT_VIEWER_COUNTRY
        HTTP_FASTLY_CLIENT_IP_COUNTRY
      ].freeze

      SECONDARY_PROVIDER_HEADERS = %w[
        HTTP_X_AZURE_CLIENTIP_COUNTRY
        HTTP_X_VERCEL_IP_COUNTRY
        HTTP_X_GEO_COUNTRY
        HTTP_X_COUNTRY_CODE
        HTTP_COUNTRY_CODE
      ].freeze

      class << self
        attr_reader :custom_resolver, :geo_header, :geo_db_path, :database_reader

        # Set a custom resolver for geo-location.
        #
        # MUST be called during single-threaded initialization. Runtime changes
        # while serving requests cause race conditions.
        #
        # In the middleware path the `ip` argument is the request's masked IP;
        # prefer it over reading the address from `env`.
        #
        # @param resolver [Proc, #call, nil] callable taking (ip, env) and
        #   returning a country code String or nil; nil disables the hook
        # @raise [ArgumentError] if resolver doesn't respond to :call
        def custom_resolver=(resolver)
          unless resolver.nil? || resolver.respond_to?(:call)
            raise ArgumentError, 'Custom resolver must respond to :call'
          end

          @custom_resolver = resolver
        end

        # Set the application-configured trusted geo header.
        #
        # Accepts either the HTTP header name ('X-Client-Country') or the Rack
        # CGI env key ('HTTP_X_CLIENT_COUNTRY'), in any case, and canonicalizes
        # to the env-key form used to read from the Rack env. Request headers
        # live under `HTTP_*` env keys (Rack 3's lowercasing rule applies to
        # *response* headers, not request env keys).
        #
        # nil or an empty/blank value clears the configured header.
        #
        # @param header [String, Symbol, nil] header name or CGI env key
        def geo_header=(header)
          @geo_header = canonical_header_key(header)
        end

        # Configure (and eagerly load) the MMDB country database, or clear it.
        #
        # Loading happens here, at configuration time, so a missing/invalid
        # path or a missing `maxmind-db` gem fails fast at boot rather than
        # per-request. The database is opened in MODE_MEMORY (read once into
        # memory at boot). nil/empty unloads any current database.
        #
        # @param path [String, nil] filesystem path to a `.mmdb` file
        # @raise [DatabaseError] if the database cannot be loaded
        def geo_db_path=(path)
          normalized = path.to_s.strip
          if normalized.empty?
            unload_database!
            return
          end

          @database_reader = load_database(normalized)
          @geo_db_path = normalized
        end

        # Inject a database reader directly (advanced/testing).
        #
        # Any object responding to #get(ip) -> Hash|nil works, letting callers
        # supply a preconfigured MaxMind::DB reader or a test double without a
        # filesystem path. Setting nil clears the database. Clears geo_db_path
        # too — a directly-injected reader has no originating path to report.
        #
        # @param reader [#get, nil]
        def database_reader=(reader)
          @geo_db_path = nil
          @database_reader = reader
        end

        # @return [Boolean] whether an MMDB database is loaded in memory
        def database_loaded?
          !@database_reader.nil?
        end

        # Clear any loaded MMDB database (drops the in-memory reader).
        # @return [void]
        def unload_database!
          @database_reader = nil
          @geo_db_path = nil
        end

        # Reset ALL boot-time geo configuration to defaults.
        # Primarily for tests and re-initialization.
        # @return [void]
        def reset!
          @custom_resolver = nil
          @geo_header = nil
          unload_database!
        end

        # Resolve the country code for an IP address.
        #
        # @param ip [String] IP address (the masked IP in the middleware path)
        # @param env [Hash] Rack environment (may carry geo headers and the
        #   `otto.via_trusted_proxy` / `otto.trusted_proxies_configured` facts)
        # @return [String] ISO 3166-1 alpha-2 country code, or {UNKNOWN}
        def resolve(ip, env = {})
          return UNKNOWN if ip.nil? || ip.empty?

          # Priority: (1+2) trusted headers, (3) custom resolver,
          # (4) local MMDB on the masked IP, (5) unknown.
          country = resolve_from_headers(env) if geo_headers_trusted?(env)
          country ||= resolve_from_custom(ip, env)
          country ||= lookup_database(ip)
          country || UNKNOWN
        end

        private

        # Resolve from header sources: the application-configured header first,
        # then the known provider headers. Callers gate this on trust.
        #
        # @param env [Hash] Rack environment
        # @return [String, nil]
        def resolve_from_headers(env)
          check_configured_header(env) || check_geo_headers(env)
        end

        # Resolve via the custom resolver hook, if configured. Never lets the
        # hook crash the request — a raise is logged (when $DEBUG) and treated
        # as "no answer".
        #
        # @param ip [String]
        # @param env [Hash]
        # @return [String, nil]
        def resolve_from_custom(ip, env)
          return nil unless @custom_resolver

          country = @custom_resolver.call(ip, env)
          country if country && valid_country_code?(country)
        rescue StandardError => e
          warn "GeoResolver custom resolver error: #{e.message}" if $DEBUG
          nil
        end

        # Whether geo headers may be trusted for this request.
        #
        # Geo headers are client-spoofable unless the request actually arrived
        # through a trusted proxy/CDN. Trust them when:
        # - no middleware decision is present (standalone resolver use — legacy
        #   behavior, preserved), OR
        # - the request came via a trusted proxy (`otto.via_trusted_proxy`), OR
        # - no trusted proxies are configured, so there is nothing to gate
        #   against (`otto.trusted_proxies_configured` is false).
        #
        # This mirrors the identity-based `otto.via_trusted_proxy` contract and
        # is independent of count-based depth mode.
        #
        # @param env [Hash] Rack environment
        # @return [Boolean]
        def geo_headers_trusted?(env)
          return true unless env.key?('otto.via_trusted_proxy')
          return true if env['otto.via_trusted_proxy']

          !env['otto.trusted_proxies_configured']
        end

        # Read the application-configured trusted geo header, if any.
        #
        # @param env [Hash] Rack environment
        # @return [String, nil] valid country code or nil
        def check_configured_header(env)
          key = @geo_header
          return nil unless key

          value = env[key]
          value if valid_country_code?(value)
        end

        # Check known CDN/infrastructure provider geo headers, in order of
        # reliability/deployment frequency.
        #
        # @param env [Hash] Rack environment
        # @return [String, nil] valid country code or nil
        def check_geo_headers(env)
          # Cloudflare, CloudFront, Fastly (most reliable, direct value).
          country = first_valid_header(env, PRIMARY_PROVIDER_HEADERS)
          return country if country

          # Akamai Edgescape (format: country_code=US,region_code=CA,...).
          if (edgescape = env['HTTP_X_AKAMAI_EDGESCAPE'])
            country = extract_akamai_country(edgescape)
            return country if valid_country_code?(country)
          end

          # Azure, Vercel, then the semi-standard names (least reliable).
          first_valid_header(env, SECONDARY_PROVIDER_HEADERS)
        end

        # Return the value of the first header (by CGI env key) that carries a
        # valid country code, or nil.
        #
        # @param env [Hash] Rack environment
        # @param keys [Array<String>] CGI env keys to check, in priority order
        # @return [String, nil]
        def first_valid_header(env, keys)
          keys.each do |key|
            value = env[key]
            return value if valid_country_code?(value)
          end
          nil
        end

        # Extract the country code from an Akamai Edgescape header value.
        #
        # Edgescape format: "country_code=US,region_code=CA,city=LA,..."
        #
        # @param edgescape [String] header value
        # @return [String, nil]
        def extract_akamai_country(edgescape)
          return nil unless edgescape.is_a?(String)

          match = edgescape.match(/country_code=([A-Z]{2})(?:,|\z)/)
          match ? match[1] : nil
        end

        # Look up the country for an IP in the loaded MMDB database.
        #
        # Returns nil (not a crash) for any lookup problem so a bad datafile or
        # a malformed address degrades to the {UNKNOWN} fallback rather than
        # taking down the request. Private/localhost addresses are skipped —
        # they are never present in a country database.
        #
        # @param ip [String] IP address (masked IP in the middleware path)
        # @return [String, nil] valid country code or nil
        def lookup_database(ip)
          reader = @database_reader
          return nil unless reader
          return nil if IPPrivacy.private_or_localhost?(ip)

          record = reader.get(ip)
          country_from_record(record)
        rescue IPAddr::InvalidAddressError
          nil
        rescue StandardError => e
          warn "GeoResolver database lookup error: #{e.message}" if $DEBUG
          nil
        end

        # Extract an ISO country code from an MMDB record, tolerating the
        # common schema variants across data sources:
        # - GeoLite2 / GeoIP2-Country and sapics geo-whois-asn-country:
        #   {"country" => {"iso_code" => "US"}} (with "registered_country" too)
        # - flat schemas: {"country_code" => "US"} or {"country" => "US"}
        #
        # @param record [Hash, nil] MMDB record
        # @return [String, nil] valid country code or nil
        def country_from_record(record)
          return nil unless record.is_a?(Hash)

          code = iso_code_from(record['country']) ||
                 iso_code_from(record['registered_country']) ||
                 (record['country_code'].is_a?(String) ? record['country_code'] : nil)

          code if valid_country_code?(code)
        end

        # Pull an ISO code out of an MMDB sub-record that may be either a nested
        # map ({"iso_code" => "US", ...}) or a bare code string ("US").
        #
        # @param value [Object]
        # @return [String, nil]
        def iso_code_from(value)
          case value
          when Hash   then value['iso_code']
          when String then value
          end
        end

        # Build an MMDB reader for +path+, wrapping failures as DatabaseError
        # so they surface clearly at boot.
        #
        # @param path [String] filesystem path to a `.mmdb` file
        # @return [#get] MMDB reader opened in MODE_MEMORY
        # @raise [DatabaseError]
        def load_database(path)
          reader_class = maxmind_reader_class

          begin
            reader_class.new(path, mode: reader_class::MODE_MEMORY)
          rescue Errno::ENOENT
            raise DatabaseError, "geo database not found at geo_db_path: #{path}"
          rescue DatabaseError
            raise
          rescue StandardError => e
            # e.g. MaxMind::DB::InvalidDatabaseError for a corrupt/non-MMDB file
            raise DatabaseError,
                  "geo database at geo_db_path is not a valid MMDB file: #{path} (#{e.class}: #{e.message})"
          end
        end

        # Load and return the MaxMind::DB reader class, or raise a clear error
        # instructing the user to add the optional `maxmind-db` gem.
        #
        # @return [Class]
        # @raise [DatabaseError]
        def maxmind_reader_class
          require 'maxmind/db'
          MaxMind::DB
        rescue LoadError => e
          raise DatabaseError,
                "geo_db_path is configured but the 'maxmind-db' gem is not available. " \
                "Add `gem 'maxmind-db'` to your Gemfile to enable the local geo database " \
                "fallback. (#{e.message})"
        end

        # Canonicalize a header name/CGI key to the Rack request env key form
        # ('HTTP_X_CLIENT_COUNTRY'). Returns nil for nil/blank input.
        #
        # @param header [String, Symbol, nil]
        # @return [String, nil]
        def canonical_header_key(header)
          return nil if header.nil?

          key = header.to_s.strip
          return nil if key.empty?

          key = key.tr('-', '_').upcase
          key = "HTTP_#{key}" unless key.start_with?('HTTP_')
          key
        end

        # Validate country-code format (ISO 3166-1 alpha-2 shape).
        #
        # @param code [Object] candidate value
        # @return [Boolean]
        def valid_country_code?(code)
          code.is_a?(String) && code.length == 2 && code.match?(/^[A-Z]{2}$/)
        end
      end
    end
  end
end
