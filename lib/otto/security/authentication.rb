# frozen_string_literal: true

# lib/otto/security/authentication.rb
#
# Index file for Otto authentication module
# Requires all authentication-related components for backward compatibility

require_relative 'authentication/auth_strategy'
require_relative 'authentication/strategy_result'
require_relative 'authentication/failure_result'
require_relative 'authentication/authentication_middleware'

# Load all strategies
require_relative 'authentication/strategies/noauth_strategy'
require_relative 'authentication/strategies/session_strategy'
require_relative 'authentication/strategies/role_strategy'
require_relative 'authentication/strategies/api_key_strategy'
require_relative 'authentication/strategies/permission_strategy'

class Otto
  module Security
    # Backward compatibility aliases for the old namespace
    AuthStrategy = Authentication::AuthStrategy
    NoAuthStrategy = Authentication::Strategies::NoAuthStrategy
    SessionStrategy = Authentication::Strategies::SessionStrategy
    RoleStrategy = Authentication::Strategies::RoleStrategy
    APIKeyStrategy = Authentication::Strategies::APIKeyStrategy
    PermissionStrategy = Authentication::Strategies::PermissionStrategy
    AuthenticationMiddleware = Authentication::AuthenticationMiddleware
  end

  # Top-level backward compatibility aliases
  StrategyResult = Security::Authentication::StrategyResult
  FailureResult = Security::Authentication::FailureResult
end
