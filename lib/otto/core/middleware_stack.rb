class Otto
  module Core
    # Enhanced middleware stack management for Otto framework.
    # Provides better middleware registration, introspection capabilities,
    # and improved execution chain management.
    class MiddlewareStack
      include Enumerable

      def initialize
        @stack = []
        @middleware_set = Set.new
      end

      # Enhanced middleware registration with argument uniqueness
      def add(middleware_class, *args, **options)
        # Check if an identical middleware configuration already exists
        existing_entry = @stack.find do |entry|
          entry[:middleware] == middleware_class &&
            entry[:args] == args &&
            entry[:options] == options
        end

        # Only add if no identical middleware configuration exists
        unless existing_entry
          entry = { middleware: middleware_class, args: args, options: options }
          @stack << entry
          @middleware_set.add(middleware_class)
          # Invalidate memoized middleware list
          @memoized_middleware_list = nil
        end
      end
      alias use add
      alias << add

      # Remove middleware
      def remove(middleware_class)
        matches = @stack.reject! { |entry| entry[:middleware] == middleware_class }

        # Update middleware set if any matching entries were found
        if matches
          # Rebuild the set of unique middleware classes
          @middleware_set = Set.new(@stack.map { |entry| entry[:middleware] })
          # Invalidate memoized middleware list
          @memoized_middleware_list = nil
        end
      end

      # Check if middleware is registered - now O(1) using Set
      def includes?(middleware_class)
        @middleware_set.include?(middleware_class)
      end

      # Clear all middleware
      def clear!
        @stack.clear
        @middleware_set.clear
        # Invalidate memoized middleware list
        @memoized_middleware_list = nil
      end

      # Enumerable support
      def each(&)
        @stack.each(&)
      end

      # Build Rack application with middleware chain
      def build_app(base_app, security_config = nil)
        @stack.reduce(base_app) do |app, entry|
          middleware = entry[:middleware]
          args = entry[:args]
          options = entry[:options]

          if middleware.respond_to?(:new)
            # Inject security_config for security middleware, placing it before custom args
            if security_config && middleware_needs_config?(middleware)
              middleware.new(app, security_config, *args, **options)
            else
              middleware.new(app, *args, **options)
            end
          else
            # Proc-based middleware
            middleware.call(app)
          end
        end
      end

      # Cached middleware list to reduce array creation
      def middleware_list
        # Memoize the result to avoid repeated array creation
        @memoized_middleware_list ||= @stack.map { |entry| entry[:middleware] }
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

      # Count occurrences of a specific middleware class
      def count(middleware_class)
        @stack.count { |entry| entry[:middleware] == middleware_class }
      end

      # Method for checking if a middleware is included is already defined on line 28

      # Legacy compatibility methods for existing Otto interface
      def reverse_each(&)
        @stack.reverse_each(&)
      end

      private

      def middleware_needs_config?(middleware_class)
        # Include all Otto security middleware that can accept security_config
        [
          Otto::Security::CSRFMiddleware,
          Otto::Security::ValidationMiddleware,
          Otto::Security::RateLimitMiddleware,
          Otto::Security::AuthenticationMiddleware,
        ].include?(middleware_class)
      end
    end
  end
end
