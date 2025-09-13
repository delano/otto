# frozen_string_literal: true

# lib/otto/security/authentication/failure_result.rb

class Otto
  module Security
    module Authentication
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
  end
end
