# frozen_string_literal: true

# lib/otto/mcp/rate_limiting.rb

require 'json'

require_relative '../security/rate_limiting'

begin
  require 'rack/attack'
rescue LoadError
  # rack-attack is optional - graceful fallback
end

class Otto
  module MCP
    # Rate limiter for MCP protocol endpoints
    class RateLimiter < Otto::Security::RateLimiting
      def self.configure_rack_attack!(config = {})
        return unless defined?(Rack::Attack)

        # Start with base configuration from general rate limiting
        super

        # Add MCP-specific rules
        configure_mcp_rules(config)
        configure_mcp_responses
        configure_mcp_logging
      end

      def self.configure_mcp_rules(config)
        # MCP endpoint requests - 60 per minute by default
        mcp_requests_limit = config[:mcp_requests_per_minute] || 60

        Rack::Attack.throttle('mcp_requests', limit: mcp_requests_limit, period: 60) do |request|
          endpoint = request.env['otto.mcp_http_endpoint'] || '/_mcp'
          request.ip if request.path.start_with?(endpoint)
        end

        # Tool calls are more expensive - 20 per minute by default
        tool_calls_limit = config[:tool_calls_per_minute] || 20

        Rack::Attack.throttle('mcp_tool_calls', limit: tool_calls_limit, period: 60) do |request|
          endpoint = request.env['otto.mcp_http_endpoint'] || '/_mcp'
          if request.path.start_with?(endpoint) && request.post?
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

      def self.configure_mcp_responses
        # Override throttled responder to provide JSON-RPC formatted responses for MCP requests
        Rack::Attack.throttled_responder = lambda do |request|
          match_data = request.env['rack.attack.match_data']
          now        = match_data[:epoch_time]

          headers = {
            'content-type' => 'application/json',
            'retry-after' => (match_data[:period] - (now % match_data[:period])).to_s,
          }

          # Check if this is an MCP request
          endpoint = request.env['otto.mcp_http_endpoint'] || '/_mcp'
          if request.path.start_with?(endpoint)
            # JSON-RPC error response for MCP
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
          else
            # Use the general rate limiting response for non-MCP requests
            accept_header = request.env['HTTP_ACCEPT'].to_s
            if accept_header.include?('application/json')
              error_response = {
                error: 'Rate limit exceeded',
                message: 'Too many requests',
                retry_after: headers['retry-after'].to_i,
                limit: match_data[:limit],
                period: match_data[:period],
              }
              [429, headers, [JSON.generate(error_response)]]
            else
              body                    = "Rate limit exceeded. Retry after #{headers['retry-after']} seconds."
              headers['content-type'] = 'text/plain'
              [429, headers, [body]]
            end
          end
        end
      end

      def self.configure_mcp_logging
        return unless defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications.subscribe('rack.attack') do |_name, _start, _finish, _request_id, payload|
          req      = payload[:request]
          endpoint = req.env['otto.mcp_http_endpoint'] || '/_mcp'

          if req.path.start_with?(endpoint)
            Otto.logger.warn "[MCP] Rate limit #{payload[:match_type]} for #{req.ip}: #{payload[:matched]}"
          else
            Otto.logger.warn "[Otto] Rate limit #{payload[:match_type]} for #{req.ip}: #{payload[:matched]}"
          end
        end
      end
    end

    # Middleware for applying rate limits to MCP protocol endpoints
    class RateLimitMiddleware < Otto::Security::RateLimitMiddleware
      def initialize(app, security_config = nil)
        @app                    = app
        @security_config        = security_config
        @rate_limiter_available = defined?(Rack::Attack)

        if @rate_limiter_available
          configure_mcp_rate_limiting
        else
          Otto.logger.warn '[MCP] rack-attack not available - rate limiting disabled'
        end
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
