# lib/otto/security/rate_limiting.rb
#
# frozen_string_literal: true
#
# Index file for rate limiting components
# Provides backward compatibility for existing rate limiting usage

require_relative 'rate_limiter'
require_relative 'middleware/rate_limit_middleware'

class Otto
  module Security
    # Backward compatibility alias
    RateLimitMiddleware = Middleware::RateLimitMiddleware
  end
end
