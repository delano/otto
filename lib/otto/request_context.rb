# frozen_string_literal: true

# lib/otto/request_context.rb

# RequestContext is an immutable data structure that provides authentication
# and session context to Otto Logic classes. It replaces the previous pattern
# of passing separate session and user parameters.
#
# @example Basic usage
#   context = RequestContext.new(
#     session: { id: 'abc123', user_id: 1 },
#     user: { name: 'John', role: 'admin', permissions: ['read', 'write'] },
#     auth_method: 'token',
#     metadata: { ip: '127.0.0.1' }
#   )
#
#   context.authenticated?  #=> true
#   context.has_role?('admin')  #=> true
#   context.user[:name]  #=> 'John'
#
class Otto
  RequestContext = Data.define(:session, :user, :auth_method, :metadata) do
    # Create an anonymous (unauthenticated) context
    # @return [RequestContext] Anonymous context with empty session and user
    def self.anonymous(metadata: {})
      new(
        session: {},
        user: {},
        auth_method: 'public',
        metadata: metadata
      )
    end

    # Create a context from an AuthResult
    # @param auth_result [Otto::Security::AuthResult] Authentication result
    # @param auth_method [String] Authentication method used
    # @param metadata [Hash] Additional context metadata
    # @return [RequestContext] Context instance
    def self.from_auth_result(auth_result, auth_method: 'unknown', metadata: {})
      if auth_result&.success?
        context = auth_result.user_context || {}
        new(
          session: context[:session] || context['session'] || {},
          user: context[:user] || context['user'] || {},
          auth_method: auth_method,
          metadata: metadata
        )
      else
        anonymous(metadata: metadata.merge(auth_failure: auth_result&.failure_reason))
      end
    end

    # Check if the request is authenticated (has a non-empty user)
    # @return [Boolean] True if user has data, false otherwise
    def authenticated?
      user.is_a?(Hash) ? !user.empty? : !user.nil?
    end

    # Check if the request is anonymous (not authenticated)
    # @return [Boolean] True if not authenticated
    def anonymous?
      !authenticated?
    end

    # Check if the user has a specific role
    # @param role [String, Symbol] Role to check
    # @return [Boolean] True if user has the role
    def has_role?(role)
      return false unless authenticated?

      user_role = user[:role] || user['role']
      user_role.to_s == role.to_s
    end

    # Check if the user has a specific permission
    # @param permission [String, Symbol] Permission to check
    # @return [Boolean] True if user has the permission
    def has_permission?(permission)
      return false unless authenticated?

      permissions = user[:permissions] || user['permissions'] || []
      permissions = [permissions] unless permissions.is_a?(Array)
      permissions.map(&:to_s).include?(permission.to_s)
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

      user[:id] || user['id'] || user[:user_id] || user['user_id'] ||
        session[:user_id] || session['user_id']
    end

    # Get user name from various possible locations
    # @return [String, nil] User name or nil
    def user_name
      return nil unless authenticated?

      user[:name] || user['name'] || user[:username] || user['username']
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
        "#<RequestContext authenticated user=#{user_name || user_id} roles=#{roles} method=#{auth_method}>"
      else
        "#<RequestContext anonymous method=#{auth_method}>"
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
end
