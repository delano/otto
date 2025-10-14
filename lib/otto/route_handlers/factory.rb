# frozen_string_literal: true

# lib/otto/route_handlers/factory.rb

require_relative 'base'

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
        handler = case route_definition.kind
                  when :logic
                    LogicClassHandler.new(route_definition, otto_instance)
                  when :instance
                    InstanceMethodHandler.new(route_definition, otto_instance)
                  when :class
                    ClassMethodHandler.new(route_definition, otto_instance)
                  else
                    raise ArgumentError, "Unknown handler kind: #{route_definition.kind}"
                  end

        # Wrap with auth enforcement if route has auth requirement
        if route_definition.auth_requirement && otto_instance&.auth_config
          require_relative '../security/authentication/route_auth_wrapper'
          handler = Otto::Security::Authentication::RouteAuthWrapper.new(
            handler,
            route_definition,
            otto_instance.auth_config,
            otto_instance.security_config
          )
        end

        handler
      end
    end
  end
end
