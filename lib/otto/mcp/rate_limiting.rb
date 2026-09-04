# lib/otto/mcp/rate_limiting.rb
#
# frozen_string_literal: true

require 'json'

require_relative '../security/rate_limiting'

class Otto
  module MCP
    # Rate limiter for MCP protocol endpoints
    class RateLimiter < Otto::Security::RateLimiting
      def self.configure_rack_attack!(config = {})
        # Start with base configuration from general rate limiting
        super

        # Add MCP-specific rules. JSON-RPC responses and [MCP] logging come from
        # the throttled_response / log_throttled_request overrides below, which
        # the base configuration already wires into Rack::Attack.
        configure_mcp_rules(config)
      end

      def self.mcp_endpoint(env)
        env['otto.mcp_http_endpoint'] || '/_mcp'
      end

      def self.mcp_request?(request)
        request.path.start_with?(mcp_endpoint(request.env))
      end

      def self.configure_mcp_rules(config)
        # MCP endpoint requests - 60 per minute by default
        mcp_requests_limit = config[:mcp_requests_per_minute] || 60

        Rack::Attack.throttle('mcp_requests', limit: mcp_requests_limit, period: 60) do |request|
          request.ip if mcp_request?(request)
        end

        # Tool calls are more expensive - 20 per minute by default
        tool_calls_limit = config[:tool_calls_per_minute] || 20

        Rack::Attack.throttle('mcp_tool_calls', limit: tool_calls_limit, period: 60) do |request|
          if mcp_request?(request) && request.post?
            begin
              body = request.body.read
              data = JSON.parse(body)
              request.ip if data['method'] == 'tools/call'
            rescue JSON::ParserError
              nil
            ensure
              request.body.rewind if request.body.respond_to?(:rewind)
            end
          end
        end
      end

      # JSON-RPC formatted 429 for MCP requests; the general Otto response
      # (route response_type, then Accept header) for everything else.
      def self.throttled_response(request)
        return super unless mcp_request?(request)

        match_data = request.env['rack.attack.match_data']
        headers    = throttle_headers(match_data)

        error_response = {
          jsonrpc: '2.0',
          id: nil,
          error: {
            code: -32_000,
            message: 'Rate limit exceeded',
            data: {
              retry_after: headers['retry-after'].to_i,
              limit: match_data[:limit],
              period: match_data[:period],
            },
          },
        }
        [429, headers, [JSON.generate(error_response)]]
      end

      # Masked address only — see the note on the base implementation in
      # Otto::Security::RateLimiting (issue #219).
      def self.log_throttled_request(payload)
        req = payload[:request]
        return super unless mcp_request?(req)

        ip = Otto::LoggingHelpers.privacy_safe_ip(req.env, req.ip)
        Otto.logger.warn "[MCP] Rate limit #{payload[:match_type]} for #{ip}: #{payload[:matched]}"
      end
    end

    # Middleware for applying rate limits to MCP protocol endpoints
    class RateLimitMiddleware < Otto::Security::RateLimitMiddleware
      def initialize(app, security_config = nil)
        @app             = app
        @security_config = security_config

        configure_mcp_rate_limiting
      end

      private

      def configure_mcp_rate_limiting
        # Get base configuration from security config
        base_config = @security_config&.rate_limiting_config || {}

        # Add MCP-specific defaults
        mcp_config = base_config.merge({
                                         mcp_requests_per_minute: 60,
          tool_calls_per_minute: 20,
                                       })

        RateLimiter.configure_rack_attack!(mcp_config)
      end
    end
  end
end
