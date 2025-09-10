# frozen_string_literal: true

# lib/otto/response_handlers.rb

class Otto
  module ResponseHandlers
    # Base response handler class
    class BaseHandler
      def self.handle(result, response, context = {})
        raise NotImplementedError, 'Subclasses must implement handle method'
      end

      def self.ensure_status_set(response, default_status = 200)
        response.status = default_status unless response.status && response.status != 0
      end
    end

    # Handler for JSON responses
    class JSONHandler < BaseHandler
      def self.handle(result, response, context = {})
        response['Content-Type'] = 'application/json'

        # Determine the data to serialize
        data = if context[:logic_instance]&.respond_to?(:response_data)
                 context[:logic_instance].response_data
               elsif result.is_a?(Hash)
                 result
               elsif result.nil?
                 { success: true }
               else
                 { success: true, data: result }
               end

        response.body = [JSON.generate(data)]
        ensure_status_set(response, context[:status_code] || 200)
      end
    end

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

    # Handler for view/template responses
    class ViewHandler < BaseHandler
      def self.handle(result, response, context = {})
        if context[:logic_instance]&.respond_to?(:view)
          response.body = [context[:logic_instance].view.render]
          response['Content-Type'] = 'text/html' unless response['Content-Type']
        elsif result.respond_to?(:to_s)
          response.body = [result.to_s]
          response['Content-Type'] = 'text/html' unless response['Content-Type']
        else
          response.body = ['']
        end

        ensure_status_set(response, context[:status_code] || 200)
      end
    end

    # Default handler that preserves existing Otto behavior
    class DefaultHandler < BaseHandler
      def self.handle(_result, response, _context = {})
        # Otto's default behavior - let the route handler manage the response
        # This handler does nothing, preserving existing behavior
        ensure_status_set(response, 200)
      end
    end

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
