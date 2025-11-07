# frozen_string_literal: true

# lib/otto/route_handlers/instance_method.rb
require 'securerandom'

require_relative 'base'

class Otto
  module RouteHandlers
    # Handler for instance methods (existing Otto pattern)
    # Maintains backward compatibility for Controller#action patterns
    class InstanceMethodHandler < BaseHandler
      def call(env, extra_params = {})
        start_time = Otto::Utils.now_in_μs
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          # Apply the same extensions and processing as original Route#call
          setup_request_response(req, res, env, extra_params)

          # Create instance and call method (existing Otto behavior)
          instance = target_class.new(req, res)
          result   = instance.send(route_definition.method_name)

          # Only handle response if response_type is not default
          if route_definition.response_type != 'default'
            handle_response(result, res, {
                              instance: instance,
                              request: req,
                            })
          end
        rescue StandardError => e
          # Check if we're being called through Otto's integrated context (vs direct handler testing)
          # In integrated context, let Otto's centralized error handler manage the response
          # In direct testing context, handle errors locally for unit testing
          if otto_instance
            # Store handler context in env for centralized error handler
            handler_name = "#{target_class}##{route_definition.method_name}"
            env['otto.handler'] = handler_name
            env['otto.handler_duration'] = Otto::Utils.now_in_μs - start_time

            raise e # Re-raise to let Otto's centralized error handler manage the response
          else
            # Direct handler testing context - handle errors locally with security improvements
            error_id = SecureRandom.hex(8)
            Otto.logger.error "[#{error_id}] #{e.class}: #{e.message}"
            Otto.logger.debug "[#{error_id}] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug

            res.status                  = 500
            res.headers['content-type'] = 'text/plain'

            if Otto.env?(:dev, :development)
              res.write "Server error (ID: #{error_id}). Check logs for details."
            else
              res.write 'An error occurred. Please try again later.'
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
