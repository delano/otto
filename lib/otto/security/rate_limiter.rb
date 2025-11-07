# frozen_string_literal: true

# lib/otto/security/rate_limiter.rb

require 'json'

begin
  require 'rack/attack'
rescue LoadError
  # rack-attack is optional - graceful fallback
end

class Otto
  module Security
    # Rate limiting implementation using Rack::Attack
    class RateLimiting
      def self.configure_rack_attack!(config = {})
        return unless defined?(Rack::Attack)

        # Use provided cache store or default
        Rack::Attack.cache.store = config[:cache_store] if config[:cache_store]

        # Default rules
        default_requests_per_minute = config.fetch(:requests_per_minute, 100)

        # General request throttling
        Rack::Attack.throttle('requests', limit: default_requests_per_minute, period: 60) do |request|
          request.ip unless request.path.start_with?('/_') # Skip internal paths by default
        end

        # Apply custom rules if provided
        if config[:custom_rules]
          config[:custom_rules].each do |name, rule_config|
            limit = rule_config[:limit]
            period = rule_config[:period] || 60
            condition = rule_config[:condition]

            Rack::Attack.throttle(name.to_s, limit: limit, period: period) do |request|
              if condition
                request.ip if condition.call(request)
              else
                request.ip
              end
            end
          end
        end

        # Custom response for rate limited requests
        Rack::Attack.throttled_responder = lambda do |request|
          match_data = request.env['rack.attack.match_data']
          now = match_data[:epoch_time]

          headers = {
            'content-type' => 'application/json',
            'retry-after' => (match_data[:period] - (now % match_data[:period])).to_s,
          }

          # Check if request expects JSON
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
            body = "Rate limit exceeded. Retry after #{headers['retry-after']} seconds."
            headers['content-type'] = 'text/plain'
            [429, headers, [body]]
          end
        end

        # Log blocked requests if ActiveSupport is available
        return unless defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications.subscribe('rack.attack') do |_name, _start, _finish, _request_id, payload|
          req = payload[:request]
          Otto.logger.warn "[Otto] Rate limit #{payload[:match_type]} for #{req.ip}: #{payload[:matched]}"
        end
      end
    end
  end
end
