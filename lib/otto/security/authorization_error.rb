# lib/otto/security/authorization_error.rb
#
# frozen_string_literal: true

class Otto
  module Security
    # Authorization error for resource-level access control failures
    #
    # This exception is designed to be raised from Logic classes when a user
    # attempts to access a resource they don't have permission to access.
    #
    # Otto automatically registers this as a 403 Forbidden error during
    # initialization, so raising this exception will return a 403 response
    # instead of a 500 error.
    #
    # Two-Layer Authorization Pattern:
    # - Layer 1 (Route-level): RouteAuthWrapper checks authentication/basic roles
    # - Layer 2 (Resource-level): Logic classes raise AuthorizationError for ownership/permissions
    #
    # @example Ownership check in Logic class
    #   class PostEditLogic
    #     def raise_concerns
    #       @post = Post.find(params[:id])
    #
    #       unless @post.user_id == @context.user_id
    #         raise Otto::Security::AuthorizationError, "Cannot edit another user's post"
    #       end
    #     end
    #   end
    #
    # @example Multi-condition authorization
    #   class OrganizationDeleteLogic
    #     def raise_concerns
    #       @org = Organization.find(params[:id])
    #
    #       unless @context.user_roles.include?('admin') || @org.owner_id == @context.user_id
    #         raise Otto::Security::AuthorizationError,
    #           "Requires admin role or organization ownership"
    #       end
    #     end
    #   end
    #
    class AuthorizationError < StandardError
      # Optional additional context for logging/debugging
      attr_reader :resource, :action, :user_id

      # Initialize authorization error with optional context
      #
      # @param message [String] Human-readable error message
      # @param resource [String, nil] Resource type being accessed (e.g., 'Post', 'Organization')
      # @param action [String, nil] Action being attempted (e.g., 'edit', 'delete')
      # @param user_id [String, Integer, nil] ID of user attempting access
      def initialize(message = 'Access denied', resource: nil, action: nil, user_id: nil)
        super(message)
        @resource = resource
        @action = action
        @user_id = user_id
      end

      # Generate structured log data for authorization failures
      #
      # @return [Hash] Hash suitable for structured logging
      def to_log_data
        {
          error: message,
          resource: resource,
          action: action,
          user_id: user_id,
        }.compact
      end
    end
  end
end
