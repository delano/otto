# lib/otto/security/authentication/authorization_failure.rb
#
# frozen_string_literal: true

class Otto
  module Security
    module Authentication
      # Result for AUTHORIZATION failures (authenticated, but not permitted).
      #
      # This is distinct from AuthFailure, which represents an AUTHENTICATION
      # failure (no/invalid/expired credential). A strategy that performs both
      # authentication and authorization in one pass (e.g. a token strategy that
      # also enforces a role/permission encoded in the route requirement) returns:
      #
      #   * AuthFailure          -> credential missing/invalid  -> 401 Unauthorized
      #   * AuthorizationFailure -> credential valid, but denied -> 403 Forbidden
      #
      # Without this type a combined strategy could only return AuthFailure, and
      # RouteAuthWrapper would collapse an authorization denial to 401 — leaving a
      # client unable to distinguish "authenticate again" from "you lack this
      # permission." The wrapper maps this type to ResponseBuilder#forbidden (403);
      # see RouteAuthWrapper#handle_all_strategies_failed.
      #
      # NOTE: Otto's built-in Layer-1 role check (RoleAuthorization, driven by the
      # `role=` route token) already yields 403 for role mismatches on a successful
      # StrategyResult. This type covers the complementary case: a strategy that
      # owns authorization itself (including permission tiers, which Layer-1 does
      # not model) and needs to signal a 403 directly.
      AuthorizationFailure = Data.define(:failure_reason, :auth_method) do
        # Authorization failures are not an authenticated request state. The
        # request never reaches the handler, so handler-facing predicates report
        # the same "no user context" shape AuthFailure does.
        #
        # @return [Boolean] False
        def authenticated?
          false
        end

        # @return [Boolean] True (no user context attached to a denial)
        def anonymous?
          true
        end

        # @return [Hash] Empty hash
        def user_context
          {}
        end

        # @return [String] Debug representation
        def inspect
          "#<AuthorizationFailure reason=#{failure_reason.inspect} method=#{auth_method}>"
        end
      end
    end
  end
end
