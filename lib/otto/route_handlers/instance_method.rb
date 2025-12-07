# lib/otto/route_handlers/instance_method.rb
#
# frozen_string_literal: true

require_relative 'base'

class Otto
  module RouteHandlers
    # Handler for instance methods (existing Otto pattern)
    # Route syntax: Controller#action
    #
    # Controller instances receive full Rack request/response access:
    # - initialize(request, response) with Rack::Request and Rack::Response
    # - Direct access to sessions, cookies, headers, and the raw env
    #
    # Use this handler for endpoints requiring request-level control (logout,
    # session management, cookie manipulation, custom header handling).
    class InstanceMethodHandler < BaseHandler
      protected

      # Invoke the instance method on the target class
      # @param req [Rack::Request] Request object
      # @param res [Rack::Response] Response object
      # @return [Array] [result, context] for handle_response
      def invoke_target(req, res)
        instance = target_class.new(req, res)
        result = instance.send(route_definition.method_name)
        [result, { instance: instance, request: req }]
      end
    end
  end
end
