# lib/otto/privacy/redacted_fingerprint.rb
#
# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'uri'

class Otto
  module Privacy
    # Immutable privacy-safe request fingerprint (aka CrappyFingerprint)
    #
    # Contains anonymized information about a request that can be used for
    # logging, analytics, and session tracking without storing personally
    # identifiable information.
    #
    # @example Create from Rack environment
    #   config = Otto::Privacy::Config.new
    #   fingerprint = RedactedFingerprint.new(env, config)
    #   fingerprint.masked_ip   # => '192.168.1.0'
    #   fingerprint.country     # => 'US'
    #
    class RedactedFingerprint
      attr_reader :session_id, :timestamp, :masked_ip, :hashed_ip,
                  :country, :anonymized_ua, :request_path,
                  :request_method, :referer

      # IP-bearing forwarded headers overwritten with the masked IP in the
      # geo-resolution env view. Mirrors the set
      # IPPrivacyMiddleware#mask_forwarded_headers rewrites, so a custom resolver
      # reading env sees masked values everywhere the middleware would. The
      # structured RFC 7239 Forwarded header (HTTP_FORWARDED) is handled
      # separately in {#geo_env} (dropped, not swapped, to keep valid syntax).
      GEO_MASKED_FORWARDED_HEADERS = %w[
        HTTP_X_FORWARDED_FOR
        HTTP_X_REAL_IP
        HTTP_X_CLIENT_IP
      ].freeze

      # Create a new RedactedFingerprint from a Rack environment
      #
      # @param env [Hash] Rack environment hash
      # @param config [Otto::Privacy::Config] Privacy configuration
      # @param geo_headers_trusted [Boolean] whether request geo headers may be
      #   trusted for this request. The middleware passes false for a
      #   non-trusted-proxy request when trusted proxies are configured, so
      #   spoofed geo headers are ignored. Defaults to true for standalone use.
      def initialize(env, config, geo_headers_trusted: true)
        remote_ip = env['REMOTE_ADDR']

        @session_id = SecureRandom.uuid
        @timestamp = Time.now.utc
        @masked_ip = IPPrivacy.mask_ip(remote_ip, config.octet_precision)
        @hashed_ip = IPPrivacy.hash_ip(remote_ip, config.rotation_key)
        # hashed_ip is computed above from the real IP; geo resolution then runs
        # against a MASKED view — the masked IP AND an env with the IP-bearing
        # headers masked — so neither a custom resolver nor the database can see
        # the unmasked address, via the argument or via env. Country-level
        # networks are >= /24, so the /24-masked IP resolves to the same country.
        @country = if config.geo_enabled
                     GeoResolver.resolve(@masked_ip, geo_env(env), config, headers_trusted: geo_headers_trusted)
                   end
        @anonymized_ua = anonymize_user_agent(env['HTTP_USER_AGENT'])
        @request_path = env['PATH_INFO']
        @request_method = env['REQUEST_METHOD']
        @referer = anonymize_referer(env['HTTP_REFERER'])

        freeze
      end

      # Convert to hash for logging or serialization
      #
      # @return [Hash] Hash representation of fingerprint
      def to_h
        {
              session_id: @session_id,
               timestamp: @timestamp.iso8601,
               masked_ip: @masked_ip,
               hashed_ip: @hashed_ip,
                 country: @country,
           anonymized_ua: @anonymized_ua,
          request_method: @request_method,
            request_path: @request_path,
                 referer: @referer,
        }
      end

      # Convert to JSON string
      #
      # @return [String] JSON representation
      def to_json(*_args)
        require 'json'
        to_h.to_json
      end

      # String representation
      #
      # @return [String] Human-readable representation
      def to_s
        "#<RedactedFingerprint #{@hashed_ip[0..15]}... #{@country} #{@timestamp}>"
      end

      # Inspect representation
      #
      # @return [String] Detailed representation for debugging
      def inspect
        '#<Otto::Privacy::RedactedFingerprint ' \
          "masked_ip=#{@masked_ip.inspect} " \
          "hashed_ip=#{@hashed_ip[0..15]}... " \
          "country=#{@country.inspect} " \
          "timestamp=#{@timestamp.inspect}>"
      end

      private

      # A shallow copy of env with the client-IP fields masked, for geo
      # resolution. Country-level geo needs nothing finer than the masked /24,
      # so a custom resolver (arbitrary app code that might log or forward what
      # it receives) is handed only the masked address here — never the raw host
      # IP that env['REMOTE_ADDR'] and the forwarded headers still carry at this
      # point in the middleware. Non-IP keys (including geo headers like
      # CF-IPCountry) are preserved. Returns env unchanged when there is no
      # masked IP (nothing to hide, and geo resolution short-circuits anyway).
      #
      # @param env [Hash] Rack environment
      # @return [Hash] masked env view
      def geo_env(env)
        return env if @masked_ip.nil?

        masked = env.dup
        masked['REMOTE_ADDR'] = @masked_ip
        GEO_MASKED_FORWARDED_HEADERS.each do |key|
          masked[key] = @masked_ip if masked.key?(key)
        end
        # HTTP_FORWARDED (RFC 7239) carries the client IP in a structured `for=`
        # token — and Otto reads it as an authoritative client-IP source in
        # depth mode with trusted_proxy_header 'Forwarded'/'Both'. A wholesale
        # swap would produce invalid Forwarded syntax, and geo resolution needs
        # nothing from it, so drop it from the geo view entirely rather than
        # leak the raw address to a custom resolver.
        masked.delete('HTTP_FORWARDED')
        masked
      end

      # Anonymize user agent string by removing version numbers and build identifiers
      #
      # Delegates to the public {UserAgentPrivacy.anonymize} so there is a single
      # source of truth for the reduction (removes version numbers and build
      # identifiers, preserving browser/OS info) shared with downstream consumers.
      #
      # @param ua [String, nil] User agent string
      # @return [String, nil] Anonymized user agent or nil
      def anonymize_user_agent(ua)
        UserAgentPrivacy.anonymize(ua)
      end

      # Anonymize referer URL
      #
      # Strips query parameters and keeps only the path to reduce
      # tracking potential while maintaining useful navigation data.
      #
      # @param referer [String, nil] Referer header value
      # @return [String, nil] Anonymized referer or nil
      def anonymize_referer(referer)
        return nil if referer.nil? || referer.empty?

        begin
          uri = URI.parse(referer)
          # Keep scheme, host, and path only (remove query and fragment)
          if uri.scheme && uri.host
            "#{uri.scheme}://#{uri.host}#{uri.path}"
          else
            uri.path
          end
        rescue URI::InvalidURIError
          # If referer is malformed, return nil
          nil
        end
      end
    end
  end
end
