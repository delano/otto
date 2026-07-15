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
        # Geo resolves on the MASKED IP so the unmasked address never reaches the
        # resolver (custom resolver / MMDB). Country-level networks are >= /24,
        # so a /24-masked address resolves to the same country as the real one.
        @country = if config.geo_enabled
                     GeoResolver.resolve(@masked_ip, env, config, headers_trusted: geo_headers_trusted)
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
