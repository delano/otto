# frozen_string_literal: true

# lib/otto/logging_helpers.rb

class Otto
  # LoggingHelpers provides utility methods for consistent structured logging
  # across the Otto framework. Centralizes common request context extraction
  # to eliminate duplication while keeping logging calls simple and explicit.
  module LoggingHelpers
    # Extract common request context for structured logging
    #
    # Returns a hash containing privacy-aware request metadata suitable
    # for merging with event-specific data in Otto.structured_log calls.
    #
    # @param env [Hash] Rack environment hash
    # @return [Hash] Request context with method, path, ip, country, user_agent
    #
    # @example Basic usage
    #   Otto.structured_log(:info, "Route matched",
    #     Otto::LoggingHelpers.request_context(env).merge(
    #       type: 'literal',
    #       handler: 'App#index'
    #     )
    #   )
    #
    # @note IP addresses are already masked by IPPrivacyMiddleware (public IPs only)
    # @note User agents are truncated to 100 chars to prevent log bloat
    def self.request_context(env)
      {
        method: env['REQUEST_METHOD'],
        path: env['PATH_INFO'],
        ip: env['REMOTE_ADDR'],  # Already masked by IPPrivacyMiddleware for public IPs
        country: env['otto.geo_country'],
        user_agent: env['HTTP_USER_AGENT']&.slice(0, 100)  # Truncate to prevent bloat
      }.compact
    end
  end
end
