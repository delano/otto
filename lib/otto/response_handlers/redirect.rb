# lib/otto/response_handlers/redirect.rb

require_relative 'base'

class Otto
  module ResponseHandlers
    # Handler for redirect responses
    class RedirectHandler < BaseHandler
      def self.handle(result, response, context = {})
        # Determine redirect path
        path = if context[:redirect_path]
                 context[:redirect_path]
               elsif context[:logic_instance]&.respond_to?(:redirect_path)
                 context[:logic_instance].redirect_path
               elsif result.is_a?(String)
                 result
               else
                 '/'
               end

        response.redirect(path)
      end
    end
  end
end
