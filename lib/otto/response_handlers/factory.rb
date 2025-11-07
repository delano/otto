# lib/otto/response_handlers/factory.rb

require_relative 'json'
require_relative 'redirect'
require_relative 'view'
require_relative 'auto'
require_relative 'default'

class Otto
  module ResponseHandlers
    # Factory for creating response handlers
    class HandlerFactory
      # Map of response type names to handler classes
      HANDLER_MAP = {
        'json' => JSONHandler,
        'redirect' => RedirectHandler,
        'view' => ViewHandler,
        'auto' => AutoHandler,
        'default' => DefaultHandler,
      }.freeze

      def self.create_handler(response_type)
        handler_class = HANDLER_MAP[response_type.to_s.downcase]

        unless handler_class
          Otto.logger.warn "Unknown response type: #{response_type}, falling back to default" if Otto.debug
          handler_class = DefaultHandler
        end

        handler_class
      end

      def self.handle_response(result, response, response_type, context = {})
        handler = create_handler(response_type)
        handler.handle(result, response, context)
      end
    end
  end
end
