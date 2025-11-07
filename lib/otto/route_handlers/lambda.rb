# lib/otto/route_handlers/lambda.rb
#
# frozen_string_literal: true
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
          # Store handler context in env for centralized error handler
          handler_name = "Lambda[#{route_definition.klass_name}]"
          env['otto.handler'] = handler_name
          env['otto.handler_duration'] = Otto::Utils.now_in_μs - start_time

          raise e # Re-raise to let Otto's centralized error handler manage the response
        end

        res.finish
      end
    end
  end
end
