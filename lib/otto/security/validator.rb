# lib/otto/security/validator.rb
#
# frozen_string_literal: true
#
# Index file for validation middleware
# Provides backward compatibility for existing validation usage

require_relative 'middleware/validation_middleware'

class Otto
  module Security
    # Backward compatibility alias
    ValidationMiddleware = Middleware::ValidationMiddleware
  end
end
