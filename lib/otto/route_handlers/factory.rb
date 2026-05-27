# lib/otto/route_handlers/factory.rb
#
# frozen_string_literal: true

require_relative 'base'
require_relative '../security/authentication/route_auth_wrapper'

class Otto
  module RouteHandlers
    # Factory for creating appropriate handlers based on route definitions
    class HandlerFactory
      # Create a handler for the given route definition
      # @param route_definition [Otto::RouteDefinition] The route definition
      # @param otto_instance [Otto] The Otto instance for configuration access
      # @return [BaseHandler] Appropriate handler for the route
      def self.create_handler(route_definition, otto_instance = nil)
        # Create base handler based on route kind
        handler_class = case route_definition.kind
                        when :logic then LogicClassHandler
                        when :instance then InstanceMethodHandler
                        when :class then ClassMethodHandler
                        else
                          raise ArgumentError, "Unknown handler kind: #{route_definition.kind}"
                        end

        handler = handler_class.new(route_definition, otto_instance)

        # Always wrap with RouteAuthWrapper to ensure env['otto.strategy_result'] is set
        # - Routes WITH auth requirement: Enforces authentication
        # - Routes WITHOUT auth requirement: Sets anonymous StrategyResult
        if otto_instance&.auth_config
          handler = Otto::Security::Authentication::RouteAuthWrapper.new(
            handler,
            route_definition,
            otto_instance.auth_config,
            otto_instance.security_config
          )
        end

        apply_handler_wrappers(handler, route_definition, otto_instance)
      end

      # Compose registered wrappers outermost-first. Built innermost-out so
      # reverse_each yields a final order of: w1(w2(...(RouteAuthWrapper(base)))).
      def self.apply_handler_wrappers(handler, route_definition, otto_instance)
        wrappers = otto_instance&.handler_wrappers
        return handler if wrappers.nil? || wrappers.empty?

        wrappers.reverse_each do |factory|
          wrapped = factory.call(route_definition, handler)
          unless wrapped.respond_to?(:call)
            raise TypeError,
                  "handler wrapper must return an object responding to :call, got #{wrapped.class}"
          end
          handler = wrapped
        end
        handler
      end
    end
  end
end
