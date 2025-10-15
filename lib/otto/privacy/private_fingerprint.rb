# frozen_string_literal: true

require 'securerandom'
require 'time'

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
    #   fingerprint = PrivateFingerprint.new(env, config)
    #   fingerprint.masked_ip   # => '192.168.1.0'
    #   fingerprint.country     # => 'US'
    #
    class PrivateFingerprint
      attr_reader :session_id, :timestamp, :masked_ip, :hashed_ip,
                  :country, :anonymized_ua, :request_path,
                  :request_method, :referer

      # Create a new PrivateFingerprint from a Rack environment
      #
      # @param env [Hash] Rack environment hash
      # @param config [Otto::Privacy::Config] Privacy configuration
      def initialize(env, config)
        remote_ip = env['REMOTE_ADDR']

        @session_id = SecureRandom.uuid
        @timestamp = Time.now.utc
        @masked_ip = IPPrivacy.mask_ip(remote_ip, config.mask_level)
        @hashed_ip = IPPrivacy.hash_ip(remote_ip, config.rotation_key)
        @country = config.geo_enabled ? GeoResolver.resolve(remote_ip, env) : nil
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
        "#<PrivateFingerprint #{@hashed_ip[0..15]}... #{@country} #{@timestamp}>"
      end

      # Inspect representation
      #
      # @return [String] Detailed representation for debugging
      def inspect
        '#<Otto::Privacy::PrivateFingerprint ' \
          "masked_ip=#{@masked_ip.inspect} " \
          "hashed_ip=#{@hashed_ip[0..15]}... " \
          "country=#{@country.inspect} " \
          "timestamp=#{@timestamp.inspect}>"
      end

      private

      # Anonymize user agent string by removing version numbers
      #
      # Removes specific version numbers (X.X.X pattern) to reduce
      # fingerprinting granularity while maintaining browser/OS info.
      #
      # @param ua [String, nil] User agent string
      # @return [String, nil] Anonymized user agent or nil
      def anonymize_user_agent(ua)
        return nil if ua.nil? || ua.empty?

        # Remove version patterns (X.X.X.X, X.X.X, X.X)
        anonymized = ua
                     .gsub(/\d+\.\d+\.\d+\.\d+/, 'X.X.X.X')
                     .gsub(/\d+\.\d+\.\d+/, 'X.X.X')
                     .gsub(/\d+\.\d+/, 'X.X')

        # Truncate if too long (prevent DoS via huge UA strings)
        anonymized.length > 500 ? anonymized[0..499] : anonymized
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
          "#{uri.scheme}://#{uri.host}#{uri.path}"
        rescue URI::InvalidURIError
          # If referer is malformed, return nil
          nil
        end
      end
    end
  end
end
