class Otto
  module Core
    # Enhanced middleware stack management for Otto framework.
    # Provides better middleware registration, introspection capabilities,
    # and improved execution chain management.
    class MiddlewareStack
      include Enumerable

      def initialize
        @stack = []
      end

      # Enhanced middleware registration
      def add(middleware_class, *args, **options)
        return if includes?(middleware_class)

        @stack << { middleware: middleware_class, args: args, options: options }
      end
      alias use add
      alias << add

      # Remove middleware
      def remove(middleware_class)
        @stack.reject! { |entry| entry[:middleware] == middleware_class }
      end

      # Check if middleware is registered
      def includes?(middleware_class)
        @stack.any? { |entry| entry[:middleware] == middleware_class }
      end

      # Clear all middleware
      def clear!
        @stack.clear
      end

      # Enumerable support
      def each(&)
        @stack.each(&)
      end

      # Build Rack application with middleware chain
      def build_app(base_app, security_config = nil)
        @stack.reverse_each.reduce(base_app) do |app, entry|
          middleware = entry[:middleware]
          args = entry[:args]
          options = entry[:options]

          if middleware.respond_to?(:new)
            # Standard Rack middleware
            # Only inject security_config if the middleware needs it AND
            # no explicit args were provided (to avoid breaking custom configs)
            if security_config && middleware_needs_config?(middleware) && args.empty?
              middleware.new(app, security_config, **options)
            else
              middleware.new(app, *args, **options)
            end
          else
            # Proc-based middleware
            middleware.call(app)
          end
        end
      end

      # Legacy compatibility - return middleware classes for existing tests
      def middleware_list
        @stack.map { |entry| entry[:middleware] }
      end

      # Detailed introspection
      def middleware_details
        @stack.map do |entry|
          {
            middleware: entry[:middleware],
            args: entry[:args],
            options: entry[:options],
          }
        end
      end

      # Statistics
      def size
        @stack.size
      end

      def empty?
        @stack.empty?
      end

      # Legacy compatibility methods for existing Otto interface
      def reverse_each(&)
        @stack.reverse_each(&)
      end

      private

      def middleware_needs_config?(middleware_class)
        # AuthenticationMiddleware receives its own auth_config through args,
        # not the security_config, so it should not be in this list
        [
          Otto::Security::CSRFMiddleware,
          Otto::Security::ValidationMiddleware,
          Otto::Security::RateLimitMiddleware,
        ].include?(middleware_class)
      end
    end
  end
end
