# frozen_string_literal: true

# lib/otto/route_handlers/lambda.rb
require 'securerandom'

require_relative 'base'

class Otto
  module RouteHandlers
    # Custom handler for lambda/proc definitions (future extension)
    class LambdaHandler < BaseHandler
      def call(env, extra_params = {})
        start_time = Otto::Utils.now_in_μs
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          # Security: Lambda handlers require pre-configured procs from Otto instance
          # This prevents code injection via eval and maintains security
          handler_name    = route_definition.klass_name
          lambda_registry = otto_instance&.config&.dig(:lambda_handlers) || {}

          lambda_proc = lambda_registry[handler_name]
          unless lambda_proc.respond_to?(:call)
            raise ArgumentError, "Lambda handler '#{handler_name}' not found in registry or not callable"
          end

          result = lambda_proc.call(req, res, extra_params)

          handle_response(result, res, {
                            lambda: lambda_proc,
            request: req,
                          })
        rescue StandardError => e
          error_id = SecureRandom.hex(8)

          # Base context pattern: create once, reuse for correlation
          base_context = Otto::LoggingHelpers.request_context(env)
          handler_name = "Lambda[#{route_definition.klass_name}]"

          Otto.structured_log(:error, "Handler execution failed",
            base_context.merge(
              handler: handler_name,
              error: e.message,
              error_class: e.class.name,
              error_id: error_id,
              duration: Otto::Utils.now_in_μs - start_time
            )
          )

          Otto::LoggingHelpers.log_backtrace(e,
            base_context.merge(handler: handler_name, error_id: error_id)
          )

          res.status                  = 500
          res.headers['content-type'] = 'text/plain'

          if Otto.env?(:dev, :development)
            res.write "Lambda handler error (ID: #{error_id}). Check logs for details."
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

        res.finish
      end
    end
  end
end
