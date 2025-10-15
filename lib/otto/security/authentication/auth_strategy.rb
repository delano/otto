# frozen_string_literal: true

# lib/otto/security/authentication/auth_strategy.rb
#
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
        # @return [Otto::Security::Authentication::StrategyResult, Otto::Security::Authentication::AuthFailure] StrategyResult for success, AuthFailure for failure
        def authenticate(env, requirement)
          raise NotImplementedError, 'Subclasses must implement #authenticate'
        end

        protected

        # Helper to create successful strategy result
        def success(user:, session: {}, auth_method: nil, **metadata)
          Otto::Security::Authentication::StrategyResult.new(
            session: session,
            user: user,
            auth_method: auth_method || self.class.name.split('::').last,
            metadata: metadata
          )
        end

        # Helper for authentication failure - return AuthFailure
        def failure(reason = nil)
          Otto.logger.debug "[#{self.class}] Authentication failed: #{reason}" if reason
          Otto::Security::Authentication::AuthFailure.new(
            failure_reason: reason || 'Authentication failed',
            auth_method: self.class.name.split('::').last
          )
        end
      end
    end
  end
end
