# frozen_string_literal: true
# lib/otto/core/error_handler.rb

require 'securerandom'
require 'json'
require 'rack/request'

class Otto
  module Core
    module ErrorHandler
      def handle_error(error, env)
        # Log error details internally but don't expose them
        error_id = SecureRandom.hex(8)
        Otto.logger.error "[#{error_id}] #{error.class}: #{error.message}"
        Otto.logger.debug "[#{error_id}] Backtrace: #{error.backtrace.join("\n")}" if Otto.debug

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
            Otto.logger.error "[#{error_id}] Error in custom error handler: #{e.message}"
          end
        end

        # Content negotiation for built-in error response
        accept_header = env['HTTP_ACCEPT'].to_s
        return json_error_response(error_id) if accept_header.include?('application/json')

        # Fallback to built-in error response
        @server_error || secure_error_response(error_id)
      end

      private

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
