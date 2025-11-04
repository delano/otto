# frozen_string_literal: true

# lib/otto/core/error_handler.rb

require 'securerandom'
require 'json'
require 'rack/request'

class Otto
  module Core
    # Error handling module providing secure error reporting and logging functionality
    module ErrorHandler
      def handle_error(error, env)
        # Check if this is a registered expected error
        if handler_config = @error_handlers[error.class.name]
          return handle_expected_error(error, env, handler_config)
        end

        # Log error details internally but don't expose them
        error_id = SecureRandom.hex(8)

        # Base context pattern: create once, reuse for correlation
        base_context = Otto::LoggingHelpers.request_context(env)

        # Include handler context if available (set by route handlers)
        log_context = base_context.merge(
          error: error.message,
          error_class: error.class.name,
          error_id: error_id
        )
        log_context[:handler] = env['otto.handler'] if env['otto.handler']
        log_context[:duration] = env['otto.handler_duration'] if env['otto.handler_duration']

        Otto.structured_log(:error, 'Unhandled error in request', log_context)

        Otto::LoggingHelpers.log_backtrace(error,
          base_context.merge(error_id: error_id))

        # Parse request for content negotiation
        begin
          Rack::Request.new(env)
        rescue StandardError
          nil
        end
        literal_routes = @routes_literal[:GET] || {}

        # Try custom 500 route first
        if found_route = literal_routes['/500']
          begin
            env['otto.error_id'] = error_id
            return found_route.call(env)
          rescue StandardError => e
            # When the custom error handler itself fails, generate a new error ID
            # to distinguish it from the original error, but link them.
            custom_handler_error_id = SecureRandom.hex(8)
            base_context = Otto::LoggingHelpers.request_context(env)

            Otto.structured_log(:error, 'Error in custom error handler',
              base_context.merge(
                error: e.message,
                error_class: e.class.name,
                error_id: custom_handler_error_id,
                original_error_id: error_id # Link to original error
              ))

            Otto::LoggingHelpers.log_backtrace(e,
              base_context.merge(error_id: custom_handler_error_id, original_error_id: error_id))
          end
        end

        # Content negotiation for built-in error response
        accept_header = env['HTTP_ACCEPT'].to_s
        return json_error_response(error_id) if accept_header.include?('application/json')

        # Fallback to built-in error response
        @server_error || secure_error_response(error_id)
      end

      private

      # Handle expected business logic errors with custom status codes and logging
      #
      # @param error [Exception] The expected error to handle
      # @param env [Hash] Rack environment hash
      # @param handler_config [Hash] Configuration from error_handlers registry
      # @return [Array] Rack response tuple [status, headers, body]
      def handle_expected_error(error, env, handler_config)
        # Generate error ID for correlation (even for expected errors)
        error_id = SecureRandom.hex(8)

        # Base context pattern: create once, reuse for correlation
        base_context = Otto::LoggingHelpers.request_context(env)

        # Include handler context if available
        log_context = base_context.merge(
          error: error.message,
          error_class: error.class.name,
          error_id: error_id,
          expected: true  # Mark as expected error
        )
        log_context[:handler] = env['otto.handler'] if env['otto.handler']
        log_context[:duration] = env['otto.handler_duration'] if env['otto.handler_duration']

        # Log at configured level (info/warn instead of error)
        log_level = handler_config[:log_level] || :info
        Otto.structured_log(log_level, 'Expected error in request', log_context)

        # Build response body
        response_body = if handler_config[:handler]
                          # Use custom handler block if provided
                          begin
                            req = Rack::Request.new(env)
                            handler_config[:handler].call(error, req)
                          rescue StandardError => e
                            # If custom handler fails, fall back to default
                            Otto.logger.warn "Error in custom error handler: #{e.message}"
                            { error: error.class.name.split('::').last, message: error.message }
                          end
                        else
                          # Default response body
                          { error: error.class.name.split('::').last, message: error.message }
                        end

        # Add error_id in development mode
        response_body[:error_id] = error_id if Otto.env?(:dev, :development)

        # Content negotiation
        accept_header = env['HTTP_ACCEPT'].to_s
        status = handler_config[:status] || 500

        if accept_header.include?('application/json')
          body = JSON.generate(response_body)
          headers = {
            'content-type' => 'application/json',
            'content-length' => body.bytesize.to_s
          }.merge(@security_config.security_headers)

          [status, headers, [body]]
        else
          # Plain text response
          body = if Otto.env?(:dev, :development)
                   "#{response_body[:error]}: #{response_body[:message]} (ID: #{error_id})"
                 else
                   "#{response_body[:error]}: #{response_body[:message]}"
                 end

          headers = {
            'content-type' => 'text/plain',
            'content-length' => body.bytesize.to_s
          }.merge(@security_config.security_headers)

          [status, headers, [body]]
        end
      end

      def secure_error_response(error_id)
        body = if Otto.env?(:dev, :development)
                 "Server error (ID: #{error_id}). Check logs for details."
               else
                 'An error occurred. Please try again later.'
               end

        headers = {
          'content-type' => 'text/plain',
          'content-length' => body.bytesize.to_s,
        }.merge(@security_config.security_headers)

        [500, headers, [body]]
      end

      def json_error_response(error_id)
        error_data = if Otto.env?(:dev, :development)
                       {
                            error: 'Internal Server Error',
                          message: 'Server error occurred. Check logs for details.',
                         error_id: error_id,
                       }
                     else
                       {
                           error: 'Internal Server Error',
                         message: 'An error occurred. Please try again later.',
                       }
                     end

        body    = JSON.generate(error_data)
        headers = {
          'content-type' => 'application/json',
          'content-length' => body.bytesize.to_s,
        }.merge(@security_config.security_headers)

        [500, headers, [body]]
      end
    end
  end
end
