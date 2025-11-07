# lib/otto/security/authentication/strategies/permission_strategy.rb
#
# frozen_string_literal: true

require_relative '../auth_strategy'

class Otto
  module Security
    module Authentication
      module Strategies
        # Permission-based authentication strategy
        class PermissionStrategy < AuthStrategy
          def initialize(required_permissions, session_key: 'user_permissions')
            @required_permissions = Array(required_permissions)
            @session_key = session_key
          end

          def authenticate(env, requirement)
            session = env['rack.session']
            return failure('No session available') unless session

            user_permissions = session[@session_key] || []
            user_permissions = Array(user_permissions)

            # Create user data from session
            user_data = { user_permissions: user_permissions, session: session }

            # Extract permission from requirement (e.g., "permission:write" -> "write")
            required_permission = requirement.split(':', 2).last

            if user_permissions.include?(required_permission)
              success(user: user_data, user_permissions: user_permissions, required_permission: required_permission)
            else
              failure("Insufficient privileges - requires permission: #{required_permission}")
            end
          end

          def user_context(env)
            session = env['rack.session']
            return {} unless session

            user_permissions = session[@session_key] || []
            { user_permissions: Array(user_permissions) }
          end
        end
      end
    end
  end
end
