# frozen_string_literal: true

# lib/otto/route_handlers.rb

class Otto
  # Pluggable Route Handler Factory
  #
  # Enables different execution patterns while maintaining backward compatibility
  module RouteHandlers
    require_relative 'route_handlers/base'
    require_relative 'route_handlers/factory'
    require_relative 'route_handlers/logic_class'
    require_relative 'route_handlers/instance_method'
    require_relative 'route_handlers/class_method'
    require_relative 'route_handlers/lambda'
  end
end
