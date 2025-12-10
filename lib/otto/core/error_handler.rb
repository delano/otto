# lib/otto/core/error_handler.rb
#
# frozen_string_literal: true

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
          error_id: error_id,
        )
        log_context[:handler] = env['otto.handler'] if env['otto.handler']
        log_context[:duration] = env['otto.handler_duration'] if env['otto.handler_duration']

        Otto.structured_log(:error, 'Unhandled error in request', log_context)

        Otto::LoggingHelpers.log_backtrace(error,
          base_context.merge(error_id: error_id))

        # Parse request for content negotiation
        begin
          Otto::Request.new(env)
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
        return json_error_response(error_id) if wants_json_response?(env)

        # Fallback to built-in error response
        @server_error || secure_error_response(error_id)
      end

      # Register an error handler for expected business logic errors
      #
      # This allows you to handle known error conditions (like missing resources,
      # expired data, rate limits) without logging them as unhandled 500 errors.
      #
      # @param error_class [Class, String] The exception class or class name to handle
      # @param status [Integer] HTTP status code to return (default: 500)
      # @param log_level [Symbol] Log level for expected errors (:info, :warn, :error)
      # @param handler [Proc] Optional block to customize error response
      #
      # @example Basic usage with status code
      #   otto.register_error_handler(Onetime::MissingSecret, status: 404, log_level: :info)
      #   otto.register_error_handler(Onetime::SecretExpired, status: 410, log_level: :info)
      #
      # @example With custom response handler
      #   otto.register_error_handler(Onetime::RateLimited, status: 429, log_level: :warn) do |error, req|
      #     {
      #       error: 'Rate limit exceeded',
      #       retry_after: error.retry_after,
      #       message: error.message
      #     }
      #   end
      #
      # @example Using string class names (for lazy loading)
      #   otto.register_error_handler('Onetime::MissingSecret', status: 404, log_level: :info)
      #
      def register_error_handler(error_class, status: 500, log_level: :info, &handler)
        ensure_not_frozen!

        # Normalize error class to string for consistent lookup
        error_class_name = error_class.is_a?(String) ? error_class : error_class.name

        @error_handlers[error_class_name] = {
          status: status,
          log_level: log_level,
          handler: handler
        }
      end

      private

      # Register all Otto framework error classes with appropriate status codes
      #
      # This method auto-registers base HTTP error classes and all framework-specific
      # error classes (Security, MCP) so that raising them automatically returns the
      # correct HTTP status code instead of 500.
      #
      # Users can override these registrations by calling register_error_handler
      # after Otto.new with custom status codes or log levels.
      #
      # @return [void]
      # @api private
      def register_framework_errors
        # Base HTTP errors (for direct use or subclassing by implementing projects)
        register_error_from_class(Otto::NotFoundError)
        register_error_from_class(Otto::BadRequestError)
        register_error_from_class(Otto::UnauthorizedError)
        register_error_from_class(Otto::ForbiddenError)
        register_error_from_class(Otto::PayloadTooLargeError)

        # Security module errors
        register_error_from_class(Otto::Security::AuthorizationError)
        register_error_from_class(Otto::Security::CSRFError)
        register_error_from_class(Otto::Security::RequestTooLargeError)
        register_error_from_class(Otto::Security::ValidationError)

        # MCP module errors
        register_error_from_class(Otto::MCP::ValidationError)
      end

      # Register an error handler using the error class as the single source of truth
      #
      # @param error_class [Class] Error class that responds to default_status and default_log_level
      # @return [void]
      # @api private
      def register_error_from_class(error_class)
        register_error_handler(
          error_class,
          status: error_class.default_status,
          log_level: error_class.default_log_level
        )
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
          expected: true # Mark as expected error
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
                            req = @request_class.new(env)
                            result = handler_config[:handler].call(error, req)

                            # Validate that custom handler returned a Hash
                            unless result.is_a?(Hash)
                              base_context = Otto::LoggingHelpers.request_context(env)
                              Otto.structured_log(:warn, 'Custom error handler returned non-hash value',
                                base_context.merge(
                                  error_class: error.class.name,
                                  handler_result_class: result.class.name,
                                  error_id: error_id
                                ))
                              result = { error: error.class.name.split('::').last, message: error.message }
                            end

                            result
                          rescue StandardError => e
                            # If custom handler fails, fall back to default
                            base_context = Otto::LoggingHelpers.request_context(env)
                            Otto.structured_log(:warn, 'Error in custom error handler',
                              base_context.merge(
                                error: e.message,
                                error_class: e.class.name,
                                original_error_class: error.class.name,
                                error_id: error_id
                              ))
                            { error: error.class.name.split('::').last, message: error.message }
                          end
                        else
                          # Default response body
                          { error: error.class.name.split('::').last, message: error.message }
                        end

        # Add error_id in development mode
        response_body[:error_id] = error_id if Otto.env?(:dev, :development)

        # Content negotiation
        status = handler_config[:status] || 500

        if wants_json_response?(env)
          body = JSON.generate(response_body)
          headers = {
            'content-type' => 'application/json',
            'content-length' => body.bytesize.to_s,
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
            'content-length' => body.bytesize.to_s,
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

      private

      # Determine if the client wants a JSON response
      # Route's response_type declaration takes precedence over Accept header
      #
      # @param env [Hash] Rack environment
      # @return [Boolean] true if JSON response is preferred
      def wants_json_response?(env)
        route_definition = env['otto.route_definition']
        (route_definition&.response_type == 'json') ||
          env['HTTP_ACCEPT'].to_s.include?('application/json')
      end
    end
  end
end
