# lib/otto/security/authentication/auth_strategy.rb
#
# frozen_string_literal: true

# Base class for all authentication strategies in Otto framework
# Provides pluggable authentication patterns that can be customized per application

class Otto
  module Security
    module Authentication
      # Base class for all authentication strategies
      class AuthStrategy
        # Check if the request meets the authentication requirements
        # @param env [Hash] Rack environment
        # @param requirement [String] Authentication requirement string
        # @return [Otto::Security::Authentication::StrategyResult,
        #          Otto::Security::Authentication::AuthFailure]
        #          StrategyResult for success, AuthFailure for failure
        def authenticate(env, requirement)
          raise NotImplementedError, 'Subclasses must implement #authenticate'
        end

        protected

        # Helper to create successful strategy result
        #
        # NOTE: strategy_name will be injected by RouteAuthWrapper after strategy execution.
        # Strategies don't know their registered name, so we pass nil here and let the wrapper
        # set it based on how the strategy was registered via add_auth_strategy(name, strategy).
        def success(user:, session: {}, auth_method: nil, **metadata)
          Otto::Security::Authentication::StrategyResult.new(
            session: session,
            user: user,
            auth_method: auth_method || self.class.name.split('::').last,
            metadata: metadata,
            strategy_name: nil # Will be set by RouteAuthWrapper
          )
        end

        # Helper for authentication failure - return AuthFailure
        #
        # Use for a missing, invalid, or expired credential. RouteAuthWrapper maps
        # this to 401 Unauthorized. For a VALID credential that is not permitted,
        # use #authorization_failure instead (403 Forbidden).
        def failure(reason = nil)
          Otto.logger.debug "[#{self.class}] Authentication failed: #{reason}" if reason
          Otto::Security::Authentication::AuthFailure.new(
            failure_reason: reason || 'Authentication failed',
            auth_method: strategy_auth_method
          )
        end

        # Helper for authorization failure - return AuthorizationFailure
        #
        # Use when the credential is valid but the authenticated subject is not
        # permitted (wrong role, missing permission). RouteAuthWrapper maps this to
        # 403 Forbidden, letting clients distinguish "authenticate again" (401) from
        # "you lack this permission" (403). See AuthorizationFailure.
        def authorization_failure(reason = nil)
          Otto.logger.debug "[#{self.class}] Authorization denied: #{reason}" if reason
          Otto::Security::Authentication::AuthorizationFailure.new(
            failure_reason: reason || 'Authorization denied',
            auth_method: strategy_auth_method
          )
        end

        private

        # Short auth_method label from the strategy class name. Anonymous strategy
        # classes (Class.new(...), common in tests) have a nil #name, so fall back
        # to a generic label rather than raising on nil#split.
        def strategy_auth_method
          (self.class.name || 'AuthStrategy').split('::').last
        end
      end
    end
  end
end
