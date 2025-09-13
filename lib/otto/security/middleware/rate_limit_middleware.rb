# frozen_string_literal: true

require_relative '../rate_limiter'

class Otto
  module Security
    module Middleware
      # Middleware for applying rate limiting to HTTP requests
      class RateLimitMiddleware
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

        def call(env)
          return @app.call(env) unless @rate_limiter_available

          # Let rack-attack handle the rate limiting
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
