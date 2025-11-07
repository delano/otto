# frozen_string_literal: true

# lib/otto/security/csrf.rb
#
# Index file for CSRF protection components
# Provides backward compatibility for existing CSRF usage

require_relative 'middleware/csrf_middleware'

class Otto
  module Security
    # Backward compatibility alias
    CSRFMiddleware = Middleware::CSRFMiddleware

    # Helper methods for CSRF token handling in views and controllers
    module CSRFHelpers
      def csrf_token
        if @csrf_token.nil? && otto.respond_to?(:security_config)
          session_id  = otto.security_config.get_or_create_session_id(req)
          @csrf_token = otto.security_config.generate_csrf_token(session_id)
        end
        @csrf_token
      end

      def csrf_meta_tag
        %(<meta name="csrf-token" content="#{csrf_token}">)
      end

      def csrf_form_tag
        %(<input type="hidden" name="#{csrf_token_key}" value="#{csrf_token}">)
      end

      def csrf_token_key
        if otto.respond_to?(:security_config)
          otto.security_config.csrf_token_key
        else
          '_csrf_token'
        end
      end
    end
  end
end
