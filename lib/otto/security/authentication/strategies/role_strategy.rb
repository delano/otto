# frozen_string_literal: true

require_relative '../auth_strategy'

class Otto
  module Security
    module Authentication
      module Strategies
        # Role-based authentication strategy
        class RoleStrategy < AuthStrategy
          def initialize(allowed_roles, session_key: 'user_roles')
            @allowed_roles = Array(allowed_roles)
            @session_key = session_key
          end

          def authenticate(env, requirement)
            session = env['rack.session']
            return failure('No session available') unless session

            user_roles = session[@session_key] || []
            user_roles = Array(user_roles)

            # Create user data from session
            user_data = { user_roles: user_roles, session: session }

            # For requirements like "role:admin", extract the role part
            if requirement.include?(':')
              required_role = requirement.split(':', 2).last
              if user_roles.include?(required_role)
                success(user: user_data, user_roles: user_roles, required_role: required_role)
              else
                failure("Insufficient privileges - requires role: #{required_role}")
              end
            else
              # For direct strategy matches, check if user has any of the allowed roles
              matching_roles = user_roles & @allowed_roles
              if matching_roles.any?
                success(user: user_data, user_roles: user_roles, allowed_roles: @allowed_roles,
                        matching_roles: matching_roles)
              else
                failure("Insufficient privileges - requires one of roles: #{@allowed_roles.join(', ')}")
              end
            end
          end

          def user_context(env)
            session = env['rack.session']
            return {} unless session

            user_roles = session[@session_key] || []
            { user_roles: Array(user_roles) }
          end
        end
      end
    end
  end
end
