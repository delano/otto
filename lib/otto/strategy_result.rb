# frozen_string_literal: true

# lib/otto/strategy_result.rb

# StrategyResult is an immutable data structure that holds the result of an
# authentication strategy. It contains session, user, and metadata needed by
# Otto Logic classes.
#
# @example Basic usage
#   result = StrategyResult.new(
#     session: { id: 'abc123', user_id: 1 },
#     user: user_model_instance,  # Actual user model, not a hash
#     auth_method: 'token',
#     metadata: { ip: '127.0.0.1' }
#   )
#
#   result.authenticated?  #=> true
#   result.has_role?('admin')  #=> true
#   result.user.name  #=> 'John' (assuming user model has name method)
#
class Otto
  StrategyResult = Data.define(:session, :user, :auth_method, :metadata) do
    # Create an anonymous (unauthenticated) result
    # @return [StrategyResult] Anonymous result with empty session and nil user
    def self.anonymous(metadata: {})
      new(
        session: {},
        user: nil,  # Changed from {} to nil - clearer semantics
        auth_method: 'anonymous',
        metadata: metadata
      )
    end

    # Check if the request is authenticated (has a user)
    # @return [Boolean] True if user is present, false otherwise
    def authenticated?
      !user.nil?
    end

    # Check if the request is anonymous (no user)
    # @return [Boolean] True if not authenticated
    def anonymous?
      user.nil?
    end

    # Success/failure methods for compatibility
    def success?
      true  # If we have a StrategyResult, authentication succeeded
    end

    def failure?
      false  # Failures return nil, not a StrategyResult
    end


    # Check if the user has a specific role
    # @param role [String, Symbol] Role to check
    # @return [Boolean] True if user has the role
    def has_role?(role)
      return false unless authenticated?

      # Try user model methods first, fall back to hash access for backward compatibility
      if user.respond_to?(:role)
        user.role.to_s == role.to_s
      elsif user.respond_to?(:has_role?)
        user.has_role?(role)
      elsif user.is_a?(Hash)
        user_role = user[:role] || user['role']
        user_role.to_s == role.to_s
      else
        false
      end
    end

    # Check if the user has a specific permission
    # @param permission [String, Symbol] Permission to check
    # @return [Boolean] True if user has the permission
    def has_permission?(permission)
      return false unless authenticated?

      # Try user model methods first, fall back to hash access for backward compatibility
      if user.respond_to?(:has_permission?)
        user.has_permission?(permission)
      elsif user.respond_to?(:permissions)
        permissions = user.permissions || []
        permissions = [permissions] unless permissions.is_a?(Array)
        permissions.map(&:to_s).include?(permission.to_s)
      elsif user.is_a?(Hash)
        permissions = user[:permissions] || user['permissions'] || []
        permissions = [permissions] unless permissions.is_a?(Array)
        permissions.map(&:to_s).include?(permission.to_s)
      else
        false
      end
    end

    # Check if the user has any of the specified roles
    # @param roles [Array<String, Symbol>] Roles to check
    # @return [Boolean] True if user has any of the roles
    def has_any_role?(*roles)
      roles.flatten.any? { |role| has_role?(role) }
    end

    # Check if the user has any of the specified permissions
    # @param permissions [Array<String, Symbol>] Permissions to check
    # @return [Boolean] True if user has any of the permissions
    def has_any_permission?(*permissions)
      permissions.flatten.any? { |permission| has_permission?(permission) }
    end

    # Get user ID from various possible locations
    # @return [String, Integer, nil] User ID or nil
    def user_id
      return nil unless authenticated?

      # Try user model methods first, fall back to hash access and session
      if user.respond_to?(:id)
        user.id
      elsif user.respond_to?(:user_id)
        user.user_id
      elsif user.is_a?(Hash)
        user[:id] || user['id'] || user[:user_id] || user['user_id']
      end || session[:user_id] || session['user_id']
    end

    # Get user name from various possible locations
    # @return [String, nil] User name or nil
    def user_name
      return nil unless authenticated?

      # Try user model methods first, fall back to hash access
      if user.respond_to?(:name)
        user.name
      elsif user.respond_to?(:username)
        user.username
      elsif user.is_a?(Hash)
        user[:name] || user['name'] || user[:username] || user['username']
      end
    end

    # Get session ID from various possible locations
    # @return [String, nil] Session ID or nil
    def session_id
      session[:id] || session['id'] || session[:session_id] || session['session_id']
    end

    # Get all user roles as an array
    # @return [Array<String>] Array of roles (empty if none)
    def roles
      return [] unless authenticated?

      roles_data = user[:roles] || user['roles']
      if roles_data.is_a?(Array)
        roles_data.map(&:to_s)
      elsif roles_data
        [roles_data.to_s]
      else
        role = user[:role] || user['role']
        role ? [role.to_s] : []
      end
    end

    # Get all user permissions as an array
    # @return [Array<String>] Array of permissions (empty if none)
    def permissions
      return [] unless authenticated?

      perms = user[:permissions] || user['permissions'] || []
      perms = [perms] unless perms.is_a?(Array)
      perms.map(&:to_s)
    end

    # Create a string representation for debugging
    # @return [String] Debug representation
    def inspect
      if authenticated?
        "#<StrategyResult authenticated user=#{user_name || user_id} roles=#{roles} method=#{auth_method}>"
      else
        "#<StrategyResult anonymous method=#{auth_method}>"
      end
    end

    # Get user context - a hash containing user-specific information and metadata
    # @return [Hash] User context hash
    def user_context
      if authenticated?
        case auth_method
        when 'session'
          { user_id: user_id, session: session }
        else
          metadata
        end
      else
        case auth_method
        when 'anonymous'
          {}
        else
          metadata
        end
      end
    end

    # Create a hash representation
    # @return [Hash] Hash representation of the context
    def to_h
      {
        session: session,
        user: user,
        auth_method: auth_method,
        metadata: metadata,
        authenticated: authenticated?,
        user_id: user_id,
        user_name: user_name,
        roles: roles,
        permissions: permissions
      }
    end
  end

  # Failure result for authentication failures
  FailureResult = Data.define(:failure_reason, :auth_method) do
    def success?
      false
    end

    def failure?
      true
    end

    def authenticated?
      false
    end

    def anonymous?
      true
    end

    def user_context
      {}
    end

    def inspect
      "#<FailureResult reason=#{failure_reason.inspect} method=#{auth_method}>"
    end
  end
end
