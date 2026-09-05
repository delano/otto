# lib/otto/security/rate_limiter.rb
#
# frozen_string_literal: true

require 'json'

require_relative '../optional_dependency'

class Otto
  module Security
    # Rate limiting implementation using Rack::Attack
    class RateLimiting
      RACK_ATTACK_REQUIREMENT = '~> 6.7'

      def self.ensure_available!
        Otto::OptionalDependency.require!(
          'rack-attack',
          RACK_ATTACK_REQUIREMENT,
          require_path: 'rack/attack',
          feature: 'Rate limiting'
        )
      end

      def self.configure_rack_attack!(config = {})
        ensure_available!

        # Use provided cache store or default
        Rack::Attack.cache.store = config[:cache_store] if config[:cache_store]

        # Default rules
        default_requests_per_minute = config.fetch(:requests_per_minute, 100)

        # General request throttling. Internal paths (/_mcp, /_status, ...)
        # are skipped by default. PATH_INFO, not Rack::Request#path: #path
        # prepends SCRIPT_NAME, so with Otto mounted under `map '/api'` the
        # internal /_mcp request read as /api/_mcp and was counted here while
        # the MCP throttle, comparing the same way, never saw it at all.
        Rack::Attack.throttle('requests', limit: default_requests_per_minute, period: 60) do |request|
          request.ip unless request.path_info.start_with?('/_')
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

        configure_responses
        configure_logging
      end

      # Rack::Attack holds a single throttled_responder and each subscriber to
      # 'rack.attack' fires on every throttle event. Subclasses override
      # throttled_response and log_throttled_request instead of registering
      # their own responder or subscriber after super, so the hosting app never
      # gets a redundant responder assignment or doubled log lines.
      def self.configure_responses
        Rack::Attack.throttled_responder = ->(request) { throttled_response(request) }
      end

      def self.configure_logging
        # Log blocked requests if ActiveSupport is available
        return unless defined?(ActiveSupport::Notifications)

        ActiveSupport::Notifications.subscribe('rack.attack') do |_name, _start, _finish, _request_id, payload|
          log_throttled_request(payload)
        end
      end

      def self.throttled_response(request)
        match_data = request.env['rack.attack.match_data']
        general_throttled_response(request, throttle_headers(match_data), match_data)
      end

      def self.throttle_headers(match_data)
        now = match_data[:epoch_time]

        {
          'content-type' => 'application/json',
          'retry-after' => (match_data[:period] - (now % match_data[:period])).to_s,
        }
      end

      # Custom response for rate limited requests
      def self.general_throttled_response(request, headers, match_data)
        # Content negotiation for rate limit response
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
          body = "Rate limit exceeded. Retry after #{headers['retry-after']} seconds."
          headers['content-type'] = 'text/plain'
          [429, headers, [body]]
        end
      end

      # Rack::Attack is mounted by the hosting app AHEAD of Otto, so this
      # subscriber sees the raw peer regardless of where IPPrivacyMiddleware
      # sits in Otto's own stack. Log a masked address, never req.ip: a
      # deployment on the default :masked profile must not write raw client
      # IPs to its logs every time a limit trips (issue #219).
      def self.log_throttled_request(payload)
        req = payload[:request]
        ip  = Otto::LoggingHelpers.privacy_safe_ip(req.env, req.ip)
        Otto.logger.warn "[Otto] Rate limit #{payload[:match_type]} for #{ip}: #{payload[:matched]}"
      end
    end
  end
end
