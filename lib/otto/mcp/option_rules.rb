# lib/otto/mcp/option_rules.rb
#
# frozen_string_literal: true

require 'uri'

require_relative 'origin_guard'
require_relative 'settings'
require_relative 'tool'

class Otto
  module MCP
    # Validation for the options that select protocol revisions, the
    # authenticator and the hosted profile (see
    # {Otto::MCP::Options::EXTENDED_ALIASES}).
    #
    # A supplied +nil+ is always refused. +authenticator: lookup(...)+ that
    # found nothing would otherwise enable an endpoint with no authentication.
    #
    # @api private
    module OptionRules
      SECRET_MIN_BYTES = 32

      # @param key [Symbol] canonical option name
      # @param value [Object] supplied value
      # @return [Object] the value in its canonical form
      # @raise [ArgumentError] if the value is not acceptable for the option
      def self.coerce(key, value)
        raise ArgumentError, "MCP #{key} was supplied as nil. Omit the option to leave it unset." if value.nil?

        case key
        when :protocol_versions then protocol_versions(value)
        when :hosted then boolean(key, value)
        when :authenticator then callable(key, value)
        when :resource_uri then http_uri(key, value, fragment: false)
        when :authorization_servers then list(key, value).map { |url| http_uri(key, url, fragment: false) }.freeze
        when :scopes_supported then Tool.normalize_scopes(list(key, value), 'MCP scopes_supported')
        when :allowed_origins then origins(value)
        when :request_state_secret then secret(key, value)
        when :server_info then server_info(value)
        when :instructions then text(key, value)
        when :cache_ttl_ms then non_negative(key, value)
        else value
        end
      end

      # Refuse combinations that would leave an endpoint less protected than
      # its options say, and fill in what the hosted profile implies.
      #
      # @param canonical [Hash] canonical options; +:protocol_versions+ is
      #   added when +:hosted+ is true and none was supplied
      # @raise [ArgumentError]
      def self.check!(canonical)
        check_authenticator!(canonical)
        check_resource!(canonical)
        check_hosted!(canonical) if canonical[:hosted]
      end

      def self.check_authenticator!(canonical)
        return unless canonical[:authenticator]

        static = !canonical[:auth_tokens].empty?
        raise ArgumentError, 'MCP authenticator and auth_tokens cannot both be set: use one way to authenticate' if static

        open = canonical[:allow_unauthenticated]
        raise ArgumentError, 'MCP authenticator and allow_unauthenticated: true contradict each other' if open
      end
      private_class_method :check_authenticator!

      def self.check_resource!(canonical)
        orphans = canonical[:authenticator] ? [] : %i[resource_uri scopes_supported].select { |key| canonical.key?(key) }
        message = "MCP #{orphans.join(' and ')} apply to an authenticator. Set authenticator: as well."
        raise ArgumentError, message unless orphans.empty?

        return if canonical.key?(:resource_uri) == canonical.key?(:authorization_servers)

        raise ArgumentError,
              'MCP resource_uri and authorization_servers are published together as the ' \
              'protected resource metadata. Set both or neither.'
      end
      private_class_method :check_resource!

      def self.check_hosted!(canonical)
        missing = %i[authenticator resource_uri authorization_servers].reject { |key| canonical.key?(key) }
        raise ArgumentError, "MCP hosted: true requires #{missing.join(', ')}" unless missing.empty?

        canonical[:protocol_versions] ||= MODERN_PROTOCOL_VERSIONS
        legacy = canonical[:protocol_versions] & LEGACY_PROTOCOL_VERSIONS
        return if legacy.empty?

        raise ArgumentError,
              "MCP hosted: true serves #{MODERN_PROTOCOL_VERSIONS.join(', ')} only, got protocol_versions #{legacy.join(', ')}"
      end
      private_class_method :check_hosted!

      def self.protocol_versions(value)
        versions = list(:protocol_versions, value)
        unknown  = versions - SUPPORTED_PROTOCOL_VERSIONS
        unless unknown.empty?
          raise ArgumentError,
                "MCP protocol_versions #{unknown.map(&:inspect).join(', ')} not supported. " \
                "Supported: #{SUPPORTED_PROTOCOL_VERSIONS.join(', ')}"
        end

        (SUPPORTED_PROTOCOL_VERSIONS & versions).freeze
      end
      private_class_method :protocol_versions

      # A String or a non-empty Array of Strings, as an Array.
      def self.list(key, value)
        entries = value.is_a?(String) ? [value] : value
        return entries if entries.is_a?(Array) && !entries.empty? && entries.all?(String)

        raise ArgumentError, "MCP #{key} must be a String or a non-empty Array of Strings, got #{value.inspect}"
      end
      private_class_method :list

      def self.boolean(key, value)
        return value if [true, false].include?(value)

        raise ArgumentError, "MCP #{key} must be true or false, got #{value.inspect}"
      end
      private_class_method :boolean

      def self.callable(key, value)
        return value if value.respond_to?(:call)

        raise ArgumentError, "MCP #{key} must respond to #call(token, env), got #{value.class}"
      end
      private_class_method :callable

      def self.http_uri(key, value, fragment:)
        uri = value.is_a?(String) ? URI.parse(value) : nil
        return value.dup.freeze if uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && (fragment || uri.fragment.nil?)

        raise ArgumentError, "MCP #{key} must be an absolute http or https URI without a fragment, got #{value.inspect}"
      rescue URI::InvalidURIError
        raise ArgumentError, "MCP #{key} must be an absolute http or https URI without a fragment, got #{value.inspect}"
      end
      private_class_method :http_uri

      # An empty Array is meaningful here: it refuses every request that has
      # an Origin header.
      def self.origins(value)
        entries = value.is_a?(String) ? [value] : value
        origin  = ->(entry) { entry.is_a?(String) && entry.match?(OriginGuard::ORIGIN) }
        invalid = entries.is_a?(Array) ? entries.reject(&origin) : [value]
        unless invalid.empty?
          raise ArgumentError,
                "MCP allowed_origins entries are scheme://host[:port] with nothing after, got #{invalid.map(&:inspect).join(', ')}"
        end

        entries.map { |entry| OriginGuard.normalize(entry).freeze }.uniq.freeze
      end
      private_class_method :origins

      def self.secret(key, value)
        return value if value.is_a?(String) && value.bytesize >= SECRET_MIN_BYTES

        raise ArgumentError, "MCP #{key} must be a String of at least #{SECRET_MIN_BYTES} bytes"
      end
      private_class_method :secret

      def self.server_info(value)
        info    = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
        named   = %w[name version].all? { |member| info[member].is_a?(String) && !info[member].strip.empty? }
        message = "MCP server_info must be a Hash with String name and version, and optionally title, got #{value.inspect}"
        raise ArgumentError, message unless named && (info.keys - %w[name version title]).empty? && info.values.all?(String)

        info.transform_values { |member| member.dup.freeze }.freeze
      end
      private_class_method :server_info

      def self.text(key, value)
        return value.dup.freeze if value.is_a?(String) && !value.strip.empty?

        raise ArgumentError, "MCP #{key} must be a non-blank String, got #{value.inspect}"
      end
      private_class_method :text

      def self.non_negative(key, value)
        return value if value.is_a?(Integer) && !value.negative?

        raise ArgumentError, "MCP #{key} must be an Integer of 0 or more, got #{value.inspect}"
      end
      private_class_method :non_negative
    end
  end
end
