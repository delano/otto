# lib/otto/core/middleware_stack.rb
#
# frozen_string_literal: true

require_relative 'freezable'

class Otto
  module Core
    # Enhanced middleware stack management for Otto framework.
    # Provides better middleware registration, introspection capabilities,
    # and improved execution chain management.
    class MiddlewareStack
      include Enumerable
      include Otto::Core::Freezable

      # Pin tiers honored by #ordered_stack, outward-ascending. #wrap folds the
      # stack with reduce, so a LATER array position is a FURTHER OUT wrapper;
      # sorting by tier therefore sorts by how early the middleware sees the
      # request. Unpinned entries are tier 0 and keep their insertion order.
      #
      # A tier is recorded on the ENTRY (as entry[:pin_tier]), not on the
      # middleware class. Entries are identified by (class, args, options), so
      # the same class can legitimately be registered more than once with
      # different configuration; a class-wide pin would drag those other
      # registrations into the pinned tier along with it.
      PIN_TIERS = {
         outermost: 1,
        entrypoint: 2,
      }.freeze

      def initialize
        @stack = []
        @middleware_set = Set.new
        @on_change_callback = nil
      end

      # Set a callback to be invoked when the middleware stack changes
      # @param callback [Proc] A callable object (e.g., method or lambda)
      def on_change(&callback)
        @on_change_callback = callback
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
        # Notify of change
        @on_change_callback&.call
      end

      # Add middleware with position hint for optimal ordering
      #
      # Positions name a place in the ARRAY; #wrap folds the array with reduce,
      # so array order is the REVERSE of execution order — the last entry is the
      # outermost wrapper and therefore the first to see a request.
      #
      # - :first/:innermost — innermost: the LAST middleware to see the request,
      #                closest to the app. Note the trap in the older `:first`
      #                spelling: it is first-in-array, hence last-to-execute.
      #                `:innermost` says the same thing in execution terms and is
      #                the preferred spelling.
      # - :last/nil  — append (outermost among currently-registered middleware,
      #                but a later append displaces it)
      # - :outermost — pin to run OUTERMOST (first to see the request) and STAY
      #                there even if more middleware is appended afterward. Unlike
      #                :last, this is order-independent: honored in #ordered_stack
      #                at build time. Use for middleware that must short-circuit
      #                ahead of everything else (e.g. the CSP report receiver,
      #                which must intercept before CSRF).
      # - :entrypoint — pin OUTSIDE even the :outermost tier: the very first
      #                middleware to touch a request. Reserved for middleware
      #                that must normalize the request before anything else can
      #                observe it. Otto pins IPPrivacyMiddleware here so every
      #                other middleware — its own, an :outermost pin, and
      #                anything the app adds via Otto#use — reads a masked
      #                REMOTE_ADDR and the canonical env['otto.client_ip'].
      #
      # @param middleware_class [Class] Middleware class
      # @param args [Array] Middleware arguments
      # @param position [Symbol, nil] Position hint (:first, :innermost, :last,
      #   :outermost, :entrypoint, or nil)
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
        when :first, :innermost
          @stack.unshift(entry)
        when *PIN_TIERS.keys
          @stack << entry.merge(pin_tier: PIN_TIERS.fetch(position))
        else
          @stack << entry # :last / nil — default append
        end

        @middleware_set.add(middleware_class)
        # Notify of change
        @on_change_callback&.call
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
          warnings << <<~MSG.chomp
            [MCP Middleware] RateLimitMiddleware should come before TokenMiddleware
          MSG
        end

        if auth_pos && validation_pos && auth_pos > validation_pos
          warnings << <<~MSG.chomp
            [MCP Middleware] TokenMiddleware should come before SchemaValidationMiddleware
          MSG
        end

        if rate_limit_pos && validation_pos && rate_limit_pos > validation_pos
          warnings << <<~MSG.chomp
            [MCP Middleware] RateLimitMiddleware should come before SchemaValidationMiddleware
          MSG
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

        # Rebuild the set of unique middleware classes. Pins need no cleanup:
        # each removed entry took its own tier with it.
        @middleware_set = Set.new(@stack.map { |entry| entry[:middleware] })
        # Notify of change
        @on_change_callback&.call
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
        # Notify of change
        @on_change_callback&.call
      end

      # Enumerable support
      def each(&)
        @stack.each(&)
      end

      # Build Rack application with middleware chain
      #
      # The stack folds via reduce, so the LAST entry becomes the OUTERMOST
      # wrapper (first to see the request). #ordered_stack moves any pinned
      # middleware (:outermost, :entrypoint) to the end so it stays outermost
      # regardless of the order middleware was registered in.
      #
      # NOT a request-path method. Its only caller is Otto's build_app!, which
      # runs at construction and again whenever the stack changes; requests are
      # served by the chain it returns. So the ordering work here (and in
      # #ordered_stack) is per-BUILD, not per-request — don't add caching
      # machinery on the assumption that it is hot.
      def wrap(base_app, security_config = nil)
        ordered_stack.reduce(base_app) do |app, entry|
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

      # Returns list of middleware classes in REGISTRATION order — the order
      # they were added, which is the reverse of execution order and ignores pin
      # tiers. Use #execution_order to see what actually runs first.
      def middleware_list
        @stack.map { |entry| entry[:middleware] }
      end

      # Returns middleware classes in EXECUTION order: the first entry is the
      # outermost wrapper #wrap builds, i.e. the first to see a request. This is
      # #middleware_list resolved through the pin tiers and reversed, so it
      # answers "what does this stack actually do?" without building the app.
      #
      # @return [Array<Class>] outermost (first to execute) first
      def execution_order
        ordered_stack.reverse.map { |entry| entry[:middleware] }
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

      # The stack ordered for #wrap: identical to @stack unless some entry is
      # pinned, in which case entries are sorted by pin tier (PIN_TIERS,
      # outward-ascending) so pinned entries move to the end (outermost) while
      # the relative order within every tier is preserved. Ruby's sort_by is not
      # stable, hence the explicit index tiebreak. Returns @stack itself (no
      # copy) in the common no-pin case, so ordinary apps are unaffected.
      #
      # Runs per build, not per request — see #wrap.
      def ordered_stack
        return @stack if @stack.none? { |entry| entry[:pin_tier] }

        @stack.each_with_index
              .sort_by { |entry, index| [entry[:pin_tier] || 0, index] }
              .map(&:first)
      end

      def middleware_needs_config?(middleware_class)
        # Include all Otto security middleware that can accept security_config
        # Support both new namespaced classes and backward compatibility aliases
        [
          Otto::Security::Middleware::CSRFMiddleware,
          Otto::Security::Middleware::ValidationMiddleware,
          Otto::Security::Middleware::RateLimitMiddleware,
          Otto::Security::Middleware::IPPrivacyMiddleware,
          Otto::Security::CSP::ReportMiddleware,
          Otto::Security::CSP::EmitMiddleware,
        ].include?(middleware_class)
      end
    end
  end
end
