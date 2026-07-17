# lib/otto/route_handlers/lambda.rb
#
# frozen_string_literal: true

require_relative 'base'

class Otto
  module RouteHandlers
    # Handler for pre-registered lambda/proc route targets (issue #41).
    #
    # Route syntax `GET /ping &health_check` parses to kind :lambda with
    # klass_name = "health_check" (the registry KEY, not a Ruby constant) and
    # method_name = nil. The proc is looked up O(1) by name from the Otto
    # instance's pre-registered lambda_handlers — no eval, no dynamic constants.
    #
    # Reuses BaseHandler#call: implements #invoke_target and guards the base's
    # constant-resolution steps (#target_class / #handler_name).
    class LambdaHandler < BaseHandler
      protected

      # No Ruby constant backs a lambda route. Returning nil (a) prevents
      # ConstantResolver.safe_const_get from raising on a registry key and
      # (b) makes BaseHandler#setup_request_response skip its target_class
      # extension block.
      def target_class
        nil
      end

      # Derive the log/handler name from the route, not target_class.name
      # (which would be nil.name -> NoMethodError inside handle_execution_error).
      def handler_name
        "Lambda[#{route_definition.klass_name}]"
      end

      # Look up the pre-registered proc and invoke it with (req, res, extra_params).
      # @return [Array] [result, context] consumed by BaseHandler#handle_response
      def invoke_target(req, res)
        handler_key = route_definition.klass_name
        lambda_proc = lambda_registry[handler_key]

        unless lambda_proc.respond_to?(:call)
          raise ArgumentError,
                "Lambda handler '#{handler_key}' is not registered or not callable"
        end

        result = lambda_proc.call(req, res, @extra_params || {})
        [result, { request: req }]
      end

      private

      # O(1) read of the frozen registry from Otto config. Tolerates the
      # direct-testing context (no otto_instance / no :config) by returning {},
      # so invoke_target raises the clear "not registered" ArgumentError.
      def lambda_registry
        return {} unless otto_instance.respond_to?(:config)

        (otto_instance.config && otto_instance.config[:lambda_handlers]) || {}
      end
    end
  end
end
