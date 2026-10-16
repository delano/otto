# lib/otto/security/csrf.rb
#
# frozen_string_literal: true
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
      # A CSRF token for the request's binding. On a safe request a binding
      # is minted when there is none. On an unsafe request only an existing
      # binding is used, as CSRFMiddleware does: a binding minted there never
      # reaches the client, because the binding cookie is set only on safe
      # requests.
      #
      # @return [String, nil] the token, or nil when an unsafe request has no
      #   binding or the security config is unavailable
      def csrf_token
        if @csrf_token.nil? && otto.respond_to?(:security_config)
          config      = otto.security_config
          session_id  = if CSRFValidation::SAFE_METHODS.include?(req.request_method.to_s.upcase)
                          config.get_or_create_session_id(req)
                        else
                          config.existing_session_id(req)
                        end
          @csrf_token = config.generate_csrf_token(session_id) if session_id
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
