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
    end
  end
end
