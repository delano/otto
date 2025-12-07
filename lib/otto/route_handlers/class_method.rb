# lib/otto/route_handlers/class_method.rb
#
# frozen_string_literal: true

require_relative 'base'

class Otto
  module RouteHandlers
    # Handler for class methods (existing Otto pattern)
    # Route syntax: Controller.action
    #
    # Class methods receive full Rack request/response access:
    # - Method signature: def self.action(request, response)
    # - Direct access to sessions, cookies, headers, and the raw env
    #
    # Use this handler for endpoints requiring request-level control (logout,
    # session management, cookie manipulation, custom header handling).
    class ClassMethodHandler < BaseHandler
      protected

      # Invoke the class method on the target class
      # @param req [Rack::Request] Request object
      # @param res [Rack::Response] Response object
      # @return [Array] [result, context] for handle_response
      def invoke_target(req, res)
        result = target_class.send(route_definition.method_name, req, res)
        [result, { class: target_class, request: req }]
      end
    end
  end
end
