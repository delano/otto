# lib/otto/route_handlers/class_method.rb
#
# frozen_string_literal: true

require 'json'
require 'securerandom'

require_relative 'base'

class Otto
  module RouteHandlers
    # Handler for class methods (existing Otto pattern)
    # Maintains backward compatibility for Controller.action patterns
    class ClassMethodHandler < BaseHandler
      def call(env, extra_params = {})
        start_time = Otto::Utils.now_in_μs
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          # Apply the same extensions and processing as original Route#call
          setup_request_response(req, res, env, extra_params)

          # Call class method directly (existing Otto behavior)
          result = target_class.send(route_definition.method_name, req, res)

          # Only handle response if response_type is not default
          if route_definition.response_type != 'default'
            handle_response(result, res,
            {
                class: target_class,
              request: req,
            })
          end
        rescue StandardError => e
          # Check if we're being called through Otto's integrated context (vs direct handler testing)
          # In integrated context, let Otto's centralized error handler manage the response
          # In direct testing context, handle errors locally for unit testing
          if otto_instance
            # Store handler context in env for centralized error handler
            handler_name = "#{target_class.name}##{route_definition.method_name}"
            env['otto.handler'] = handler_name
            env['otto.handler_duration'] = Otto::Utils.now_in_μs - start_time

            raise e # Re-raise to let Otto's centralized error handler manage the response
          else
            # Direct handler testing context - handle errors locally with security improvements
            error_id = SecureRandom.hex(8)
            Otto.logger.error "[#{error_id}] #{e.class}: #{e.message}"
            Otto.logger.debug "[#{error_id}] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug

            res.status = 500

            # Content negotiation for error response
            accept_header = env['HTTP_ACCEPT'].to_s
            if accept_header.include?('application/json')
              res.headers['content-type'] = 'application/json'
              error_data                  = {
                   error: 'Internal Server Error',
                 message: 'Server error occurred. Check logs for details.',
                error_id: error_id,
              }
              res.write JSON.generate(error_data)
            else
              res.headers['content-type'] = 'text/plain'
              res.write "Server error (ID: #{error_id}). Check logs for details."
            end

            # Add security headers if available
            if otto_instance.respond_to?(:security_config) && otto_instance.security_config
              otto_instance.security_config.security_headers.each do |header, value|
                res.headers[header] = value
              end
            end
          end
        end

        finalize_response(res)
      end
    end
  end
end
