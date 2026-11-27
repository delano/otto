# lib/otto/mcp/settings.rb
#
# frozen_string_literal: true

class Otto
  module MCP
    # What the protocol handler needs to know about how its endpoint was
    # enabled. Built once by {Otto::MCP::Server#enable!} and never changed.
    Settings = Data.define(:protocol_versions, :hosted, :auth, :server_info, :instructions, :cache_ttl_ms,
      :request_state) do
      # @return [Otto::MCP::Settings] an endpoint that speaks 2024-11-05 only
      #   and has no authenticator: what Otto served before these settings
      #   existed
      def self.legacy
        new(
          protocol_versions: Otto::MCP::LEGACY_PROTOCOL_VERSIONS,
          hosted: false,
          auth: nil,
          server_info: { 'name' => 'Otto MCP Server', 'version' => Otto::VERSION }.freeze,
          instructions: nil,
          cache_ttl_ms: 0,
          request_state: nil
        )
      end

      # @return [Array<String>] served revisions that carry their version and
      #   capabilities on every request
      def modern_versions
        protocol_versions & Otto::MCP::MODERN_PROTOCOL_VERSIONS
      end

      # @return [Array<String>] served revisions that open with +initialize+
      def legacy_versions
        protocol_versions & Otto::MCP::LEGACY_PROTOCOL_VERSIONS
      end

      def modern?
        !modern_versions.empty?
      end

      def legacy?
        !legacy_versions.empty?
      end
    end

    # Revisions that establish a connection with an +initialize+ request.
    LEGACY_PROTOCOL_VERSIONS = %w[2024-11-05].freeze

    # Revisions in which every request states its version and capabilities.
    MODERN_PROTOCOL_VERSIONS = %w[2026-07-28].freeze

    # Every revision an endpoint can be configured to serve, newest first.
    SUPPORTED_PROTOCOL_VERSIONS = (MODERN_PROTOCOL_VERSIONS + LEGACY_PROTOCOL_VERSIONS).freeze
  end
end
