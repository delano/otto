# frozen_string_literal: true

# lib/otto/security/authentication/failure_result.rb

class Otto
  module Security
    module Authentication
      # Failure result for authentication failures
      AuthFailure = Data.define(:failure_reason, :auth_method) do
        # AuthFailure represents authentication failure
        # Returned by strategies when authentication fails
        # Contains failure reason for error messages

        # Check if authenticated - always false for failures
        #
        # @return [Boolean] False (failures are never authenticated)
        def authenticated?
          false
        end

        # Check if anonymous - always true for failures
        #
        # @return [Boolean] True (failures have no user)
        def anonymous?
          true
        end

        # Get empty user context for failures
        #
        # @return [Hash] Empty hash
        def user_context
          {}
        end

        # Create a string representation for debugging
        #
        # @return [String] Debug representation
        def inspect
          "#<AuthFailure reason=#{failure_reason.inspect} method=#{auth_method}>"
        end
      end
    end
  end
end
