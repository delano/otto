require 'json'

begin
  require 'rack/attack'
rescue LoadError
  # rack-attack is optional - graceful fallback
end

class Otto
  module MCP
    class RateLimiter
      def self.configure_rack_attack!
        return unless defined?(Rack::Attack)

        # Configure memory store for rate limiting
        # Use ActiveSupport::Cache::MemoryStore if available, otherwise use simple Hash-based store
        if defined?(ActiveSupport)
          Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
        else
          # Simple fallback cache store for basic rate limiting
          Rack::Attack.cache.store = Hash.new { |h, k| h[k] = {} }
        end

        # Throttle MCP requests - 60 requests per minute per IP
        Rack::Attack.throttle('mcp_requests', limit: 60, period: 60) do |request|
          endpoint = request.env['otto.mcp_http_endpoint'] || '/_mcp'
          request.ip if request.path.start_with?(endpoint)
        end

        # Throttle tool calls more strictly - 20 tool calls per minute per IP
        Rack::Attack.throttle('mcp_tool_calls', limit: 20, period: 60) do |request|
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

        # Custom response for rate limited requests (updated API)
        Rack::Attack.throttled_responder = lambda do |request|
          match_data = request.env['rack.attack.match_data']
          now = match_data[:epoch_time]

          headers = {
            'content-type' => 'application/json',
            'retry-after' => (match_data[:period] - (now % match_data[:period])).to_s
          }

          error_response = {
            jsonrpc: '2.0',
            id: nil,
            error: {
              code: -32000,
              message: 'Rate limit exceeded',
              data: {
                retry_after: headers['retry-after'].to_i,
                limit: match_data[:limit],
                period: match_data[:period]
              }
            }
          }

          [429, headers, [JSON.generate(error_response)]]
        end

        # Log blocked requests
        ActiveSupport::Notifications.subscribe('rack.attack') do |name, start, finish, request_id, payload|
          req = payload[:request]
          Otto.logger.warn "[MCP] Rate limit #{payload[:match_type]} for #{req.ip}: #{payload[:matched]}"
        end if defined?(ActiveSupport::Notifications)
      end
    end

    class RateLimitMiddleware
      def initialize(app, security_config = nil)
        @app = app
        @rate_limiter_available = defined?(Rack::Attack)

        if @rate_limiter_available
          # Use default limits for now - we'll make this configurable later
          @limits = {
            requests_per_minute: 60,
            tools_per_minute: 20
          }
          configure_limits
        else
          Otto.logger.warn "[MCP] rack-attack not available - rate limiting disabled"
        end
      end

      def call(env)
        return @app.call(env) unless @rate_limiter_available

        # Let rack-attack handle the rate limiting
        @app.call(env)
      end

      private

      def configure_limits
        RateLimiter.configure_rack_attack!
      end
    end
  end
end
