# lib/otto/security/authentication.rb

# lib/otto/security/authentication.rb
#
# Index file for Otto authentication module
# Requires all authentication-related components for backward compatibility

require_relative 'authentication/auth_strategy'
require_relative 'authentication/strategy_result'
require_relative 'authentication/auth_failure'
require_relative 'authentication/route_auth_wrapper'

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
  end

  # Top-level backward compatibility aliases
  StrategyResult = Security::Authentication::StrategyResult
  AuthFailure = Security::Authentication::AuthFailure
end
