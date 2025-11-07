# frozen_string_literal: true

require_relative 'base'
require_relative 'json'
require_relative 'redirect'
require_relative 'view'
require_relative 'default'

class Otto
  module ResponseHandlers
    # Auto-detection handler that chooses appropriate handler based on context
    class AutoHandler < BaseHandler
      def self.handle(result, response, context = {})
        # Auto-detect based on result type and request context
        handler_class = detect_handler_type(result, response, context)
        handler_class.handle(result, response, context)
      end

      def self.detect_handler_type(result, response, context)
        # Check if response type was already set by the handler
        content_type = response['Content-Type']

        if content_type&.include?('application/json')
          JSONHandler
        elsif (context[:logic_instance]&.respond_to?(:redirect_path) && context[:logic_instance].redirect_path) ||
              (result.is_a?(String) && result.match?(%r{^/}))
          # Logic instance has redirect path or result is a string path
          RedirectHandler
        elsif result.is_a?(Hash)
          JSONHandler
        elsif context[:logic_instance]&.respond_to?(:view)
          ViewHandler
        else
          DefaultHandler
        end
      end
    end
  end
end
