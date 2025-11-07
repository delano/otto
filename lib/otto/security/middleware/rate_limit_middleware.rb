# lib/otto/security/middleware/rate_limit_middleware.rb
#
# frozen_string_literal: true

require_relative '../rate_limiter'

class Otto
  module Security
    module Middleware
      # Middleware for applying rate limiting to HTTP requests
      class RateLimitMiddleware
        # NOTE: This middleware is a CONFIGURATOR, not an enforcer.
        #
        # Actual rate limiting is performed by Rack::Attack globally via
        # configure_rack_attack!. This middleware registers during initialization
        # and then passes through all requests.
        #
        # To enforce rate limits, Rack::Attack must be added to the middleware
        # stack BEFORE Otto's router (typically done by the hosting application).
        #
        # Example (config.ru):
        #   use Rack::Attack  # Must come before Otto
        #   run otto
        #
        # The call method is a pass-through; rate limiting happens in Rack::Attack.

        def initialize(app, security_config = nil)
          @app = app
          @security_config = security_config
          @rate_limiter_available = defined?(Rack::Attack)

          if @rate_limiter_available
            configure_rate_limiting
          else
            Otto.logger.warn '[Otto] rack-attack not available - rate limiting disabled'
          end
        end

        # Pass-through call - actual rate limiting handled by Rack::Attack
        #
        # This middleware does not enforce limits itself. It configures
        # Rack::Attack during initialization, then delegates all requests.
        def call(env)
          @app.call(env)
        end

        private

        def configure_rate_limiting
          config = @security_config&.rate_limiting_config || {}
          Otto::Security::RateLimiting.configure_rack_attack!(config)
        end
      end
    end
  end
end
