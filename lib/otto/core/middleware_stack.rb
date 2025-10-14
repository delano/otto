# frozen_string_literal: true

# lib/otto/core/middleware_stack.rb

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

      # Enhanced middleware registration with argument uniqueness and immutability check
      def add(middleware_class, *args, **options)
        # Prevent modifications to frozen configurations
        raise FrozenError, 'Cannot modify frozen middleware stack' if frozen?

        # Check if an identical middleware configuration already exists
        existing_entry = @stack.find do |entry|
          entry[:middleware] == middleware_class &&
            entry[:args] == args &&
            entry[:options] == options
        end

        # Only add if no identical middleware configuration exists
        return if existing_entry

        entry = { middleware: middleware_class, args: args, options: options }
        @stack << entry
        @middleware_set.add(middleware_class)
        # Invalidate memoized middleware list
        @memoized_middleware_list = nil
      end

      # Add middleware with position hint for optimal ordering
      #
      # @param middleware_class [Class] Middleware class
      # @param args [Array] Middleware arguments
      # @param position [Symbol, nil] Position hint (:first, :last, or nil for append)
      # @option options [Symbol] :position Position hint (:first or :last)
      def add_with_position(middleware_class, *args, position: nil, **options)
        raise FrozenError, 'Cannot modify frozen middleware stack' if frozen?

        # Check for identical configuration
        existing_entry = @stack.find do |entry|
          entry[:middleware] == middleware_class &&
            entry[:args] == args &&
            entry[:options] == options
        end

        return if existing_entry

        entry = { middleware: middleware_class, args: args, options: options }

        case position
        when :first
          @stack.unshift(entry)
        when :last
          @stack << entry
        else
          @stack << entry  # Default append
        end

        @middleware_set.add(middleware_class)
        @memoized_middleware_list = nil
      end

      # Validate MCP middleware ordering
      #
      # MCP middleware must be in security-optimal order:
      # 1. RateLimitMiddleware (reject excessive requests early)
      # 2. Auth middleware (validate credentials before parsing)
      # 3. SchemaValidationMiddleware (expensive JSON schema validation last)
      #
      # @return [Array<String>] Warning messages if order is suboptimal
      def validate_mcp_middleware_order
        warnings = []

        # PERFORMANCE NOTE: This implementation intentionally uses select + find_index
        # rather than a single-pass approach. The filtered mcp_middlewares array is
        # typically 0-3 items, making the performance difference unmeasurable.
        # The current approach prioritizes readability over micro-optimization.
        # Single-pass alternatives were considered but rejected as premature optimization.
        mcp_middlewares = @stack.select do |entry|
          [
            Otto::MCP::RateLimitMiddleware,
            Otto::MCP::Auth::TokenMiddleware,
            Otto::MCP::SchemaValidationMiddleware,
          ].include?(entry[:middleware])
        end

        return warnings if mcp_middlewares.size < 2

        # Find positions
        rate_limit_pos = mcp_middlewares.find_index { |e| e[:middleware] == Otto::MCP::RateLimitMiddleware }
        auth_pos = mcp_middlewares.find_index { |e| e[:middleware] == Otto::MCP::Auth::TokenMiddleware }
        validation_pos = mcp_middlewares.find_index { |e| e[:middleware] == Otto::MCP::SchemaValidationMiddleware }

        # Check optimal order: rate_limit < auth < validation
        if rate_limit_pos && auth_pos && rate_limit_pos > auth_pos
          warnings << '[MCP Middleware] RateLimitMiddleware should come before TokenMiddleware for optimal performance'
        end

        if auth_pos && validation_pos && auth_pos > validation_pos
          warnings << '[MCP Middleware] TokenMiddleware should come before SchemaValidationMiddleware for optimal performance'
        end

        if rate_limit_pos && validation_pos && rate_limit_pos > validation_pos
          warnings << '[MCP Middleware] RateLimitMiddleware should come before SchemaValidationMiddleware for optimal performance'
        end

        warnings
      end
      alias use add
      alias << add

      # Remove middleware
      def remove(middleware_class)
        # Prevent modifications to frozen configurations
        raise FrozenError, 'Cannot modify frozen middleware stack' if frozen?

        matches = @stack.reject! { |entry| entry[:middleware] == middleware_class }

        # Update middleware set if any matching entries were found
        return unless matches

        # Rebuild the set of unique middleware classes
        @middleware_set = Set.new(@stack.map { |entry| entry[:middleware] })
        # Invalidate memoized middleware list
        @memoized_middleware_list = nil
      end

      # Check if middleware is registered - now O(1) using Set
      def includes?(middleware_class)
        @middleware_set.include?(middleware_class)
      end

      # Clear all middleware
      def clear!
        # Prevent modifications to frozen configurations
        raise FrozenError, 'Cannot modify frozen middleware stack' if frozen?

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
      def wrap(base_app, security_config = nil)
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

      # NOTE: The includes? method is defined earlier for O(1) lookup using a Set

      # Legacy compatibility methods for existing Otto interface
      def reverse_each(&)
        @stack.reverse_each(&)
      end

      private

      def middleware_needs_config?(middleware_class)
        # Include all Otto security middleware that can accept security_config
        # Support both new namespaced classes and backward compatibility aliases
        [
          Otto::Security::Middleware::CSRFMiddleware,
          Otto::Security::Middleware::ValidationMiddleware,
          Otto::Security::Middleware::RateLimitMiddleware,
          # Backward compatibility aliases
          Otto::Security::CSRFMiddleware,
          Otto::Security::ValidationMiddleware,
          Otto::Security::RateLimitMiddleware,
        ].include?(middleware_class)
      end
    end
  end
end
