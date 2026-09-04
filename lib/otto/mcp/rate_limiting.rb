# lib/otto/mcp/rate_limiting.rb
#
# frozen_string_literal: true

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
      DEFAULT_HTTP_ENDPOINT = '/_mcp'

      def self.configure_rack_attack!(config = {})
        return unless defined?(Rack::Attack)

        # Start with base configuration from general rate limiting
        super

        # Add MCP-specific rules
        configure_mcp_rules(config)
        configure_mcp_responses(config)
        configure_mcp_logging(config)
      end

      # Resolve the MCP endpoint a Rack::Attack callback should match against.
      #
      # Rack::Attack is mounted by the hosting app OUTSIDE Otto and runs before
      # every Otto middleware, including the proc that sets
      # env['otto.mcp_http_endpoint'], so inside a throttle that env key is
      # absent. The endpoint therefore has to arrive with the configuration
      # (Server#apply_rate_limits publishes it as :mcp_http_endpoint). The env
      # key is kept as a fallback for callers that run Rack::Attack inside
      # Otto's own stack, and the documented default closes the chain.
      #
      # @param configured [String, nil] endpoint from the rate limiting config
      # @param env [Hash] the request env
      # @return [String]
      def self.mcp_endpoint_for(configured, env)
        configured || env['otto.mcp_http_endpoint'] || DEFAULT_HTTP_ENDPOINT
      end

      def self.configure_mcp_rules(config)
        # Captured once, outside the blocks: they run per request, long after
        # this configuration hash is gone.
        configured_endpoint = config[:mcp_http_endpoint]

        # MCP endpoint requests - 60 per minute by default
        mcp_requests_limit = config[:mcp_requests_per_minute] || 60

        Rack::Attack.throttle('mcp_requests', limit: mcp_requests_limit, period: 60) do |request|
          endpoint = mcp_endpoint_for(configured_endpoint, request.env)
          request.ip if request.path.start_with?(endpoint)
        end

        # Tool calls are more expensive - 20 per minute by default
        tool_calls_limit = config[:tool_calls_per_minute] || 20

        Rack::Attack.throttle('mcp_tool_calls', limit: tool_calls_limit, period: 60) do |request|
          endpoint = mcp_endpoint_for(configured_endpoint, request.env)
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

      def self.configure_mcp_responses(config = {})
        configured_endpoint = config[:mcp_http_endpoint]

        # Override throttled responder to provide JSON-RPC formatted responses for MCP requests
        Rack::Attack.throttled_responder = lambda do |request|
          match_data = request.env['rack.attack.match_data']
          now        = match_data[:epoch_time]

          headers = {
            'content-type' => 'application/json',
            'retry-after' => (match_data[:period] - (now % match_data[:period])).to_s,
          }

          # Check if this is an MCP request
          endpoint = mcp_endpoint_for(configured_endpoint, request.env)
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
            # Route's response_type takes precedence over Accept header
            route_def = request.env['otto.route_definition']
            wants_json = (route_def&.response_type == 'json') ||
                         request.env['HTTP_ACCEPT'].to_s.include?('application/json')

            if wants_json
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

      def self.configure_mcp_logging(config = {})
        return unless defined?(ActiveSupport::Notifications)

        configured_endpoint = config[:mcp_http_endpoint]

        # Masked address only — see the note on the sibling subscriber in
        # Otto::Security::RateLimiting.configure_rack_attack! (issue #219).
        ActiveSupport::Notifications.subscribe('rack.attack') do |_name, _start, _finish, _request_id, payload|
          req      = payload[:request]
          endpoint = mcp_endpoint_for(configured_endpoint, req.env)
          ip       = Otto::LoggingHelpers.privacy_safe_ip(req.env, req.ip)

          if req.path.start_with?(endpoint)
            Otto.logger.warn "[MCP] Rate limit #{payload[:match_type]} for #{ip}: #{payload[:matched]}"
          else
            Otto.logger.warn "[Otto] Rate limit #{payload[:match_type]} for #{ip}: #{payload[:matched]}"
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

        # MCP defaults, overridden by anything the security config carries
        # (Server#apply_rate_limits publishes the configured limits and the
        # endpoint there).
        mcp_config = {
          mcp_requests_per_minute: 60,
          tool_calls_per_minute: 20,
        }.merge(base_config)

        RateLimiter.configure_rack_attack!(mcp_config)
      end
    end
  end
end
