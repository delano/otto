# frozen_string_literal: true

# lib/otto/security/authentication.rb
#
# Configurable authentication strategy system for Otto framework
# Provides pluggable authentication patterns that can be customized per application
#
# Usage:
#   otto = Otto.new('routes.txt', {
#     auth_strategies: {
#       'publicly' => PublicStrategy.new,
#       'authenticated' => SessionStrategy.new,
#       'role:admin' => RoleStrategy.new(['admin']),
#       'api_key' => APIKeyStrategy.new
#     }
#   })

class Otto
  module Security
    # Base class for all authentication strategies
    class AuthStrategy
      # Check if the request meets the authentication requirements
      # @param env [Hash] Rack environment
      # @param requirement [String] Authentication requirement string
      # @return [AuthResult] Result containing success status and context
      def authenticate(env, requirement)
        raise NotImplementedError, 'Subclasses must implement #authenticate'
      end

      # Optional: Extract user context for authenticated requests
      # @param env [Hash] Rack environment
      # @return [Hash] User context hash
      def user_context(_env)
        {}
      end

      protected

      # Helper to create successful auth result
      def success(user_context = {})
        AuthResult.new(true, user_context)
      end

      # Helper to create failed auth result
      def failure(reason = 'Authentication failed')
        AuthResult.new(false, {}, reason)
      end
    end

    # Result object for authentication attempts
    class AuthResult
      attr_reader :user_context, :failure_reason

      def initialize(success, user_context = {}, failure_reason = nil)
        @success = success
        @user_context = user_context
        @failure_reason = failure_reason
      end

      def success?
        @success
      end

      def failure?
        !@success
      end
    end

    # Public access strategy - always allows access
    class PublicStrategy < AuthStrategy
      def authenticate(_env, _requirement)
        success
      end
    end

    # Session-based authentication strategy
    class SessionStrategy < AuthStrategy
      def initialize(session_key: 'user_id', session_store: nil)
        @session_key = session_key
        @session_store = session_store
      end

      def authenticate(env, _requirement)
        session = env['rack.session']
        return failure('No session available') unless session

        user_id = session[@session_key]
        return failure('Not authenticated') unless user_id

        success(user_id: user_id, session: session)
      end

      def user_context(env)
        session = env['rack.session']
        return {} unless session

        user_id = session[@session_key]
        user_id ? { user_id: user_id } : {}
      end
    end

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

        # For requirements like "role:admin", extract the role part
        if requirement.include?(':')
          required_role = requirement.split(':', 2).last
          if user_roles.include?(required_role)
            success(user_roles: user_roles, required_role: required_role)
          else
            failure("Insufficient privileges - requires role: #{required_role}")
          end
        else
          # For direct strategy matches, check if user has any of the allowed roles
          matching_roles = user_roles & @allowed_roles
          if matching_roles.any?
            success(user_roles: user_roles, allowed_roles: @allowed_roles, matching_roles: matching_roles)
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

    # API key authentication strategy
    class APIKeyStrategy < AuthStrategy
      def initialize(api_keys: [], header_name: 'X-API-Key', param_name: 'api_key')
        @api_keys = Array(api_keys)
        @header_name = header_name
        @param_name = param_name
      end

      def authenticate(env, _requirement)
        # Try header first, then query parameter
        api_key = env["HTTP_#{@header_name.upcase.tr('-', '_')}"]

        if api_key.nil?
          request = Rack::Request.new(env)
          api_key = request.params[@param_name]
        end

        return failure('No API key provided') unless api_key

        if @api_keys.empty? || @api_keys.include?(api_key)
          success(api_key: api_key)
        else
          failure('Invalid API key')
        end
      end
    end

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

        # Extract permission from requirement (e.g., "permission:write" -> "write")
        required_permission = requirement.split(':', 2).last

        if user_permissions.include?(required_permission)
          success(user_permissions: user_permissions, required_permission: required_permission)
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

    # Authentication middleware that enforces route-level auth requirements
    class AuthenticationMiddleware
      def initialize(app, config = {})
        @app = app
        @config = config
        @strategies = config[:auth_strategies] || {}
        @default_strategy = config[:default_auth_strategy] || 'publicly'

        # Add default public strategy if not provided
        @strategies['publicly'] ||= PublicStrategy.new
      end

      def call(env)
        # Check if this route has auth requirements
        route_definition = env['otto.route_definition']
        return @app.call(env) unless route_definition

        auth_requirement = route_definition.auth_requirement
        return @app.call(env) unless auth_requirement

        # Find appropriate strategy
        strategy = find_strategy(auth_requirement)
        return auth_error_response("Unknown authentication strategy: #{auth_requirement}") unless strategy

        # Perform authentication
        auth_result = strategy.authenticate(env, auth_requirement)

        if auth_result.success?
          # Add user context to environment for handlers to use
          env['otto.user_context'] = auth_result.user_context
          env['otto.auth_result'] = auth_result
          @app.call(env)
        else
          auth_error_response(auth_result.failure_reason)
        end
      end

      private

      def find_strategy(requirement)
        # Try exact match first - this has highest priority
        return @strategies[requirement] if @strategies[requirement]

        # For colon-separated requirements like "role:admin", try prefix match
        if requirement.include?(':')
          prefix = requirement.split(':', 2).first

          # Check if we have a strategy registered for the prefix
          prefix_strategy = @strategies[prefix]
          return prefix_strategy if prefix_strategy

          # Try fallback patterns for role: and permission: requirements
          if requirement.start_with?('role:')
            return @strategies['role'] || RoleStrategy.new([])
          elsif requirement.start_with?('permission:')
            return @strategies['permission'] || PermissionStrategy.new([])
          end
        end

        nil
      end

      def auth_error_response(message)
        body = JSON.generate({
                               error: 'Authentication Required',
          message: message,
          timestamp: Time.now.to_i,
                             })

        headers = {
          'Content-Type' => 'application/json',
          'Content-Length' => body.bytesize.to_s,
        }

        # Add security headers if available from config hash or Otto instance
        if @config.is_a?(Hash) && @config[:security_headers]
          headers.merge!(@config[:security_headers])
        elsif @config.respond_to?(:security_config) && @config.security_config
          headers.merge!(@config.security_config.security_headers)
        end

        [401, headers, [body]]
      end
    end
  end
end
