# lib/otto/security/csrf_enforcement_wrapper.rb
#
# frozen_string_literal: true

require_relative 'csrf_validation'

class Otto
  module Security
    # Per-route CSRF enforcement, applied at the handler layer.
    #
    # CSRF enforcement lives here rather than in the global +CSRFMiddleware+
    # because +csrf=exempt+ is a per-route option: it is only known once a
    # route has been matched (the middleware runs *ahead* of route matching and
    # never sees route options, so a global block could not honor exemption —
    # issue #186). This wrapper runs after matching, alongside +RouteAuthWrapper+,
    # where +route_definition.csrf_exempt?+ is directly available. It is composed
    # by +HandlerFactory+ only when CSRF protection is enabled, and wraps outside
    # +RouteAuthWrapper+ so a forged unsafe request is rejected before any
    # authentication work runs.
    #
    # The global +CSRFMiddleware+ retains only token *injection* into HTML
    # responses (a response-shaping concern that is method/content-type based,
    # not route based, so it stays global).
    class CSRFEnforcementWrapper
      include CSRFValidation

      attr_reader :wrapped_handler, :route_definition, :config

      # @param wrapped_handler [#call] the handler to guard
      # @param route_definition [Otto::RouteDefinition] the matched route
      # @param config [Otto::Security::Config] security config exposing CSRF settings
      def initialize(wrapped_handler, route_definition, config)
        @wrapped_handler  = wrapped_handler
        @route_definition = route_definition
        @config           = config
      end

      # @param env [Hash] Rack environment
      # @param extra_params [Hash] Additional parameters passed through to the handler
      # @return [Array] Rack response tuple
      def call(env, extra_params = {})
        return wrapped_handler.call(env, extra_params) unless enforce?(env)

        request = Otto::Request.new(env)
        return wrapped_handler.call(env, extra_params) if valid_csrf_token?(request)

        Otto.structured_log(:warn, 'CSRF validation failed',
          Otto::LoggingHelpers.request_context(env).merge(
            handler: route_definition.definition,
            referrer: request.referrer
          ))
        csrf_error_response
      end

      private

      # Whether this request must present a valid CSRF token. Only unsafe
      # methods on a non-exempt route are enforced when protection is enabled.
      def enforce?(env)
        return false unless config&.csrf_enabled?
        return false if safe_method?(env['REQUEST_METHOD'])
        return false if route_definition.csrf_exempt?

        true
      end
    end
  end
end
