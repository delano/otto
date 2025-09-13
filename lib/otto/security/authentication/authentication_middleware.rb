# frozen_string_literal: true

require_relative 'strategy_result'
require_relative 'failure_result'
require_relative 'strategies/public_strategy'
require_relative 'strategies/role_strategy'
require_relative 'strategies/permission_strategy'

class Otto
  module Security
    module Authentication
      # Authentication middleware that enforces route-level auth requirements
      class AuthenticationMiddleware
        def initialize(app, security_config = {}, config = {})
          @app = app
          @security_config = security_config
          @config = config
          @strategies = config[:auth_strategies] || {}
          @default_strategy = config[:default_auth_strategy] || 'publicly'

          # Add default public strategy if not provided
          @strategies['publicly'] ||= Strategies::PublicStrategy.new
        end

        def call(env)
          # Check if this route has auth requirements
          route_definition = env['otto.route_definition']

          # If no route definition, create anonymous result and continue
          unless route_definition
            env['otto.strategy_result'] = Otto::Security::Authentication::StrategyResult.anonymous(
              metadata: { ip: env['REMOTE_ADDR'] }
            )
            return @app.call(env)
          end

          auth_requirement = route_definition.auth_requirement

          # If no auth requirement, create anonymous result and continue
          unless auth_requirement
            env['otto.strategy_result'] = Otto::Security::Authentication::StrategyResult.anonymous(
              metadata: { ip: env['REMOTE_ADDR'] }
            )
            return @app.call(env)
          end

          # Find appropriate strategy
          strategy = find_strategy(auth_requirement)
          return auth_error_response("Unknown authentication strategy: #{auth_requirement}") unless strategy

          # Perform authentication
          strategy_result = strategy.authenticate(env, auth_requirement)

          if strategy_result&.success?
            # Success - store the strategy result directly
            env['otto.strategy_result'] = strategy_result
            env['otto.user'] = strategy_result.user # For convenience
            env['otto.user_context'] = strategy_result.user_context # For convenience
            @app.call(env)
          else
            # Failure - create anonymous result with failure info
            failure_reason = strategy_result&.failure_reason || 'Authentication failed'
            env['otto.strategy_result'] = Otto::Security::Authentication::StrategyResult.anonymous(
              metadata: {
                ip: env['REMOTE_ADDR'],
                auth_failure: failure_reason,
                attempted_strategy: auth_requirement,
              }
            )
            auth_error_response(failure_reason)
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
              return @strategies['role'] || Strategies::RoleStrategy.new([])
            elsif requirement.start_with?('permission:')
              return @strategies['permission'] || Strategies::PermissionStrategy.new([])
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
end
