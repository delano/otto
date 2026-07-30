# lib/otto/security/authentication/auth_failure.rb
#
# frozen_string_literal: true

class Otto
  module Security
    module Authentication
      # Failure result for authentication failures
      AuthFailure = Data.define(:failure_reason, :auth_method, :terminal) do
        # AuthFailure represents authentication failure
        # Returned by strategies when authentication fails
        # Contains failure reason for error messages
        #
        # TERMINAL FAILURES
        # -----------------
        # By default a failure is non-terminal: RouteAuthWrapper records it and
        # consults the next strategy in the route's chain (OR logic), so a
        # request without credentials can still fall through to an
        # anonymous-capable strategy like noauth.
        #
        # A failure constructed with `terminal: true` means "this request
        # explicitly presented credentials and they were examined and
        # rejected — do not consult further strategies." RouteAuthWrapper
        # halts the chain and renders the 401 with this failure's reason,
        # regardless of where the strategy sits in the chain. This lets mixed
        # credentialed/anonymous chains (e.g. auth=basicauth,noauth) fail
        # closed on invalid credentials instead of silently degrading to
        # anonymous.
        #
        # Only reject terminally when credentials were EXPLICITLY presented
        # (e.g. an Authorization header). Ambient credentials such as session
        # cookies should fail non-terminally so a logged-out browser can still
        # degrade to anonymous on noauth-capable routes.

        # terminal defaults to false so existing keyword construction
        # (failure_reason:, auth_method:) is unaffected.
        def initialize(failure_reason:, auth_method:, terminal: false)
          super
        end

        # Check if this failure halts the strategy chain
        #
        # @return [Boolean] True when the chain must fail closed
        def terminal?
          terminal
        end

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
          "#<AuthFailure reason=#{failure_reason.inspect} method=#{auth_method}#{' terminal' if terminal}>"
        end
      end
    end
  end
end
