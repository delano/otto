# lib/otto/core/lifecycle_hooks.rb
#
# frozen_string_literal: true

class Otto
  module Core
    # Lifecycle hooks module for registering callbacks at various points in request processing.
    # Provides the public API for request completion callbacks.
    module LifecycleHooks
      # Register a callback to be executed after each request completes
      #
      # Instance-level request completion callbacks allow each Otto instance
      # to have its own isolated set of callbacks, preventing duplicate
      # invocations in multi-app architectures (e.g., Rack::URLMap).
      #
      # The callback receives three arguments:
      # - request: Rack::Request object
      # - response: Rack::Response object (wrapping the response tuple)
      # - duration: Request processing duration in microseconds
      #
      # @example Basic usage
      #   otto = Otto.new(routes_file)
      #   otto.on_request_complete do |req, res, duration|
      #     logger.info "Request completed", path: req.path, duration: duration
      #   end
      #
      # @example Multi-app architecture
      #   # App 1: Core Web Application
      #   core_router = Otto.new
      #   core_router.on_request_complete do |req, res, duration|
      #     logger.info "Core app request", path: req.path
      #   end
      #
      #   # App 2: API Application
      #   api_router = Otto.new
      #   api_router.on_request_complete do |req, res, duration|
      #     logger.info "API request", path: req.path
      #   end
      #
      #   # Each callback only fires for its respective Otto instance
      #
      # @yield [request, response, duration] Block to execute after each request
      # @yieldparam request [Rack::Request] The request object
      # @yieldparam response [Rack::Response] The response object
      # @yieldparam duration [Integer] Duration in microseconds
      # @return [self] Returns self for method chaining
      # @raise [FrozenError] if called after configuration is frozen
      def on_request_complete(&block)
        ensure_not_frozen!
        @request_complete_callbacks << block if block_given?
        self
      end

      # Get registered request completion callbacks (for internal use)
      #
      # @api private
      # @return [Array<Proc>] Array of registered callback blocks
      def request_complete_callbacks
        @request_complete_callbacks
      end

      # Register a callback fired after a route matches but before the handler dispatches.
      #
      # The callback receives two arguments:
      # - env: the Rack environment hash
      # - route_definition: the matched Otto::RouteDefinition
      #
      # Unlike on_request_complete, exceptions raised inside on_route_matched callbacks
      # are NOT swallowed: they propagate to Otto#handle_error so consumers can route
      # custom error classes through register_error_handler.
      #
      # Does not fire for static-file routes or for the 404 fallback route.
      #
      # @example
      #   otto.on_route_matched do |env, route_definition|
      #     raise MyApp::Maintenance if maintenance? && route_definition.auth_requirement
      #   end
      #
      # @yield [env, route_definition] Block to execute after route match
      # @yieldparam env [Hash] The Rack environment
      # @yieldparam route_definition [Otto::RouteDefinition] The matched route definition
      # @return [self] Returns self for method chaining
      # @raise [FrozenError] if called after configuration is frozen
      def on_route_matched(&block)
        ensure_not_frozen!
        @route_matched_callbacks << block if block_given?
        self
      end

      # Get registered route matched callbacks (for internal use)
      #
      # @api private
      # @return [Array<Proc>] Array of registered callback blocks
      def route_matched_callbacks
        @route_matched_callbacks
      end

      # Register a wrapper factory that composes around each route handler.
      #
      # The block is invoked once per request, identical to RouteAuthWrapper
      # instantiation, with the route's definition and the inner (already
      # wrapped) handler. It must return either the original inner_handler (to
      # opt out for that route) or a new object responding to :call(env).
      # Wrappers compose outermost-first in registration order:
      #
      #   request -> wrapper_1 -> wrapper_2 -> ... -> RouteAuthWrapper -> base_handler
      #
      # RouteAuthWrapper always stays innermost so env['otto.strategy_result'] is set
      # before any consumer wrapper sees the request.
      #
      # Factory blocks are exercised once against every loaded route during
      # freeze_configuration! (see validate_handler_wrappers!) so factories that
      # raise unconditionally or return non-callables surface at boot rather
      # than on the first request that happens to match.
      #
      # @example Gate a route by an option set in the routes file
      #   otto.register_handler_wrapper do |route_definition, inner_handler|
      #     next inner_handler unless route_definition.option(:scope) == 'canonical'
      #     MyApp::CanonicalOnlyWrapper.new(inner_handler, route_definition)
      #   end
      #
      # @yield [route_definition, inner_handler] Factory invoked per request
      # @yieldparam route_definition [Otto::RouteDefinition] The route being wrapped
      # @yieldparam inner_handler [#call] The handler to wrap (RouteAuthWrapper or base)
      # @yieldreturn [#call] A callable wrapper, or inner_handler unchanged to skip
      # @return [self] Returns self for method chaining
      # @raise [FrozenError] if called after configuration is frozen
      def register_handler_wrapper(&block)
        ensure_not_frozen!
        @handler_wrappers << block if block_given?
        self
      end

      # Get registered handler wrapper factories (for internal use)
      #
      # @api private
      # @return [Array<Proc>] Array of registered wrapper factory blocks
      def handler_wrappers
        @handler_wrappers
      end
    end
  end
end
