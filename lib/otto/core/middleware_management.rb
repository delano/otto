# lib/otto/core/middleware_management.rb
#
# frozen_string_literal: true

class Otto
  module Core
    # Middleware management module for building and configuring the Rack middleware stack.
    # Provides the public API for adding middleware and building the application.
    module MiddlewareManagement
      # Builds the middleware application chain
      # Called once at initialization and whenever middleware stack changes
      #
      # IMPORTANT: If you have routes with auth requirements, you MUST add session
      # middleware to your middleware stack BEFORE Otto processes requests.
      #
      # Session middleware is required for RouteAuthWrapper to correctly persist
      # session changes during authentication. Common options include:
      # - Rack::Session::Cookie (requires rack-session gem)
      # - Rack::Session::Pool
      # - Rack::Session::Memcache
      # - Any Rack-compatible session middleware
      #
      # Example:
      #   use Rack::Session::Cookie, secret: ENV['SESSION_SECRET']
      #   otto = Otto.new('routes.txt')
      #
      def build_app!
        base_app = method(:handle_request)
        @app = @middleware.wrap(base_app, @security_config)
      end

      # Add middleware to the stack
      #
      # @param middleware [Class] Middleware class to add
      # @param args Additional arguments passed to middleware constructor
      def use(middleware, ...)
        ensure_not_frozen!
        @middleware.add(middleware, ...)

        # NOTE: If build_app! is triggered during a request (via use() or
        # middleware_stack=), the @app instance variable could be swapped
        # mid-request in a multi-threaded environment.

        build_app! if @app # Rebuild app if already initialized
      end

      # Compatibility method for existing tests
      # @return [Array] List of middleware classes
      def middleware_stack
        @middleware.middleware_list
      end

      # Compatibility method for existing tests
      # @param stack [Array] Array of middleware classes
      def middleware_stack=(stack)
        @middleware.clear!
        Array(stack).each { |middleware| @middleware.add(middleware) }
        build_app! if @app # Rebuild app if already initialized
      end

      # Check if a specific middleware is enabled
      #
      # @param middleware_class [Class] Middleware class to check
      # @return [Boolean] true if middleware is in the stack
      def middleware_enabled?(middleware_class)
        @middleware.includes?(middleware_class)
      end
    end
  end
end
