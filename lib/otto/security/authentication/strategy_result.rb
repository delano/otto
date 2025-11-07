# lib/otto/security/authentication/strategy_result.rb
#
# frozen_string_literal: true

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
  module Security
    module Authentication
      StrategyResult = Data.define(:session, :user, :auth_method, :metadata, :strategy_name) do
        # =====================================================================
        # USAGE PATTERNS - READ THIS FIRST
        # =====================================================================
        #
        # StrategyResult represents authentication state for a request.
        # It serves TWO distinct purposes that must not be confused:
        #
        # 1. REQUEST STATE: Current session/user information
        #    - Use `authenticated?` to check if session has a user
        #    - Available on ALL requests (anonymous or authenticated)
        #
        # 2. AUTH ATTEMPT OUTCOME: Whether authentication just succeeded
        #    - Use `auth_attempt_succeeded?` to check if auth strategy ran
        #    - Only true when route had auth=... requirement AND succeeded
        #
        # CREATION PATTERNS
        # -----------------
        #
        # StrategyResult should ONLY be created by:
        #
        # 1. Otto's AuthenticationMiddleware (automatic, route-based)
        #    - Routes WITH auth=...: Creates result from strategy execution
        #    - Routes WITHOUT auth=...: Creates anonymous result
        #
        # 2. Auth app router (manual, for Logic class compatibility)
        #    - Manually builds StrategyResult for Roda routes
        #    - Maintains same interface as Otto controllers
        #
        # APPLICATION CODE SHOULD NOT manually create StrategyResult!
        # Instead, access session directly or rely on middleware.
        #
        # SESSION CONTRACT
        # ----------------
        #
        # For multi-app architectures with shared session:
        #
        # Required session keys for authenticated state:
        #   session['authenticated']     # Boolean flag
        #   session['identity_id']       # User/customer ID
        #   session['authenticated_at']  # Timestamp
        #
        # Optional session keys:
        #   session['email']            # User email
        #   session['ip_address']       # Client IP
        #   session['user_agent']       # Client UA
        #   session['locale']           # User locale
        #
        # Advanced mode adds:
        #   session['account_external_id']  # Rodauth external_id
        #   session['advanced_account_id']  # Rodauth account ID
        #
        # EXAMPLES
        # --------
        #
        # Check if user in session (registration flow):
        #   class CreateAccount
        #     def raise_concerns
        #       # Block registration if already logged in
        #       raise FormError, "Already signed up" if @context.authenticated?
        #     end
        #   end
        #
        # Check if auth just succeeded (post-login redirect):
        #   class LoginHandler
        #     def process
        #       if @context.auth_attempt_succeeded?
        #         redirect_to dashboard_path
        #       end
        #     end
        #   end
        #
        # Distinguish between the two:
        #   @context.authenticated?           #=> true (user in session)
        #   @context.auth_attempt_succeeded?  #=> false (no auth route)
        #
        #   # vs route with auth=session:
        #   @context.authenticated?           #=> true (user in session)
        #   @context.auth_attempt_succeeded?  #=> true (strategy just ran)
        #
        # =====================================================================

        # Create an anonymous (unauthenticated) result
        #
        # Used by middleware for routes without auth requirements
        # and by PublicStrategy for publicly accessible routes.
        #
        # @param metadata [Hash] Optional metadata (IP, user agent, etc.)
        # @return [StrategyResult] Anonymous result with nil user
        def self.anonymous(metadata: {}, strategy_name: 'anonymous')
          new(
            session: {},
            user: nil,
            auth_method: 'anonymous',
            metadata: metadata,
            strategy_name: strategy_name
          )
        end

        # Check if the request has an authenticated user in session
        #
        # This checks REQUEST STATE, not auth attempt outcome.
        # Returns true if session contains a user, regardless of
        # whether authentication just occurred or was from a previous request.
        #
        # @return [Boolean] True if user is present in session
        # @example
        #   # Block registration if user already logged in
        #   raise FormError if @context.authenticated?
        def authenticated?
          !user.nil?
        end

        # Check if authentication strategy just executed and succeeded
        #
        # This checks AUTH ATTEMPT OUTCOME, not just session state.
        # Returns true only when:
        # 1. Route had an auth=... requirement (not anonymous/public)
        # 2. Auth strategy executed
        # 3. Authentication succeeded (user authenticated)
        #
        # @return [Boolean] True if auth strategy just succeeded
        # @example
        #   # Redirect after successful login
        #   redirect_to dashboard if @context.auth_attempt_succeeded?
        def auth_attempt_succeeded?
          authenticated? && auth_method.to_s != 'anonymous'
        end

        # Check if the request is anonymous (no user in session)
        #
        # @return [Boolean] True if not authenticated
        def anonymous?
          user.nil?
        end

        # Check if the user has a specific role
        #
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
        #
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
        #
        # @param roles [Array<String, Symbol>] Roles to check
        # @return [Boolean] True if user has any of the roles
        def has_any_role?(*roles)
          roles.flatten.any? { |role| has_role?(role) }
        end

        # Check if the user has any of the specified permissions
        #
        # @param permissions [Array<String, Symbol>] Permissions to check
        # @return [Boolean] True if user has any of the permissions
        def has_any_permission?(*permissions)
          permissions.flatten.any? { |permission| has_permission?(permission) }
        end

        # Get user ID from various possible locations
        #
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
        #
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
        #
        # @return [String, nil] Session ID or nil
        def session_id
          session[:id] || session['id'] || session[:session_id] || session['session_id']
        end

        # Get all user roles as an array
        #
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
        #
        # @return [Array<String>] Array of permissions (empty if none)
        def permissions
          return [] unless authenticated?

          perms = user[:permissions] || user['permissions'] || []
          perms = [perms] unless perms.is_a?(Array)
          perms.map(&:to_s)
        end

        # Create a string representation for debugging
        #
        # @return [String] Debug representation
        def inspect
          if authenticated?
            "#<StrategyResult authenticated user=#{user_name || user_id} roles=#{roles} method=#{auth_method}>"
          else
            "#<StrategyResult anonymous method=#{auth_method}>"
          end
        end

        # Get user context - a hash containing user-specific information and metadata
        #
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
        #
        # @return [Hash] Hash representation of the context
        def to_h
          {
            session: session,
            user: user,
            auth_method: auth_method,
            metadata: metadata,
            authenticated: authenticated?,
            auth_attempt_succeeded: auth_attempt_succeeded?,
            user_id: user_id,
            user_name: user_name,
            roles: roles,
            permissions: permissions
          }
        end
      end
    end
  end
end
