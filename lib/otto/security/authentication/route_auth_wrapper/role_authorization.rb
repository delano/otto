# frozen_string_literal: true

class Otto
  module Security
    module Authentication
      module RouteAuthWrapperComponents
        # Handles Layer 1 (route-level) role-based authorization
        #
        # Extracts user roles from authentication results and checks against
        # route requirements using OR logic (user needs ANY of the required roles).
        #
        # @example
        #   authorizer = RoleAuthorization.new(route_definition)
        #   authorizer.check!(strategy_result, env)  # raises or returns true
        #
        # @note This is Layer 1 authorization only. Layer 2 (resource-level)
        #   authorization should be handled in Logic classes via raise_concerns.
        #
        class RoleAuthorization
          # @param route_definition [RouteDefinition] Route with role requirements
          def initialize(route_definition)
            @route_definition = route_definition
          end

          # Check if authentication result satisfies role requirements
          #
          # @param result [StrategyResult] Authentication result
          # @param env [Hash] Rack environment (for logging)
          # @return [true] if authorized
          # @return [Hash] failure info if not authorized: { authorized: false, required: [...], actual: [...] }
          def check(result, env)
            role_requirements = @route_definition.role_requirements
            return true if role_requirements.empty?

            user_roles = extract_roles(result)

            # OR logic: user needs ANY of the required roles
            if (user_roles & role_requirements).any?
              log_success(env, role_requirements, user_roles)
              true
            else
              log_failure(env, role_requirements, user_roles, result)
              {
                authorized: false,
                required: role_requirements,
                actual: user_roles,
              }
            end
          end

          # Check authorization, returning boolean
          #
          # @param result [StrategyResult] Authentication result
          # @return [Boolean] true if authorized
          def authorized?(result)
            role_requirements = @route_definition.role_requirements
            return true if role_requirements.empty?

            user_roles = extract_roles(result)
            (user_roles & role_requirements).any?
          end

          # Get the role requirements for error messages
          #
          # @return [Array<String>] Required roles
          def requirements
            @route_definition.role_requirements
          end

          private

          # Extract user roles from authentication result
          #
          # Supports multiple role sources in order of precedence:
          # 1. result.user_roles (Array)
          # 2. result.user[:roles] (Array)
          # 3. result.user['roles'] (Array)
          # 4. result.metadata[:user_roles] (Array)
          #
          # @param result [StrategyResult] Authentication result
          # @return [Array<String>] Array of role strings
          def extract_roles(result)
            # Try direct user_roles accessor (e.g., from RoleStrategy)
            return Array(result.user_roles) if result.respond_to?(:user_roles) && result.user_roles

            # Try user hash/object with roles
            if result.user
              roles = result.user[:roles] || result.user['roles']
              return Array(roles) if roles
            end

            # Try metadata
            return Array(result.metadata[:user_roles]) if result.metadata && result.metadata[:user_roles]

            # No roles found
            []
          end

          def log_success(env, required_roles, user_roles)
            Otto.structured_log(:debug, 'Role authorization succeeded',
              Otto::LoggingHelpers.request_context(env).merge(
                required_roles: required_roles,
                user_roles: user_roles,
                matched_roles: user_roles & required_roles
              ))
          end

          def log_failure(env, required_roles, user_roles, result)
            Otto.structured_log(:warn, 'Role authorization failed',
              Otto::LoggingHelpers.request_context(env).merge(
                required_roles: required_roles,
                user_roles: user_roles,
                user_id: result.user_id
              ))
          end
        end
      end
    end
  end
end
