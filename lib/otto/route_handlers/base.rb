# lib/otto/route_handlers/base.rb

require 'json'

class Otto
  module RouteHandlers
    # Base class for all route handlers
    # Provides common functionality and interface
    class BaseHandler
      attr_reader :route_definition, :otto_instance

      def initialize(route_definition, otto_instance = nil)
        @route_definition = route_definition
        @otto_instance    = otto_instance
      end

      # Execute the route handler
      # @param env [Hash] Rack environment
      # @param extra_params [Hash] Additional parameters
      # @return [Array] Rack response array
      def call(env, extra_params = {})
        raise NotImplementedError, 'Subclasses must implement #call'
      end

      protected

      # Get the target class, loading it safely
      # @return [Class] The target class
      def target_class
        @target_class ||= safe_const_get(route_definition.klass_name)
      end

      # Setup request and response with the same extensions and processing as Route#call
      # @param req [Rack::Request] Request object
      # @param res [Rack::Response] Response object
      # @param env [Hash] Rack environment
      # @param extra_params [Hash] Additional parameters
      def setup_request_response(req, res, env, extra_params)
        # Apply the same extensions as original Route#call
        req.extend Otto::RequestHelpers
        res.extend Otto::ResponseHelpers
        res.request = req

        # Make security config available to response helpers
        if otto_instance.respond_to?(:security_config) && otto_instance.security_config
          env['otto.security_config'] = otto_instance.security_config
        end

        # Make route definition and options available to middleware and handlers
        env['otto.route_definition'] = route_definition
        env['otto.route_options']    = route_definition.options

        # Process parameters through security layer
        req.params.merge! extra_params
        req.params.replace Otto::Static.indifferent_params(req.params)

        # Add security headers
        if otto_instance.respond_to?(:security_config) && otto_instance.security_config
          otto_instance.security_config.security_headers.each do |header, value|
            res.headers[header] = value
          end
        end

        # Setup class extensions if target_class is available
        if target_class
          target_class.extend Otto::Route::ClassMethods
          target_class.otto = otto_instance if otto_instance
        end

        # Add security helpers if CSRF is enabled
        if otto_instance.respond_to?(:security_config) && otto_instance.security_config&.csrf_enabled?
          res.extend Otto::Security::CSRFHelpers
        end

        # Add validation helpers
        res.extend Otto::Security::ValidationHelpers
      end

      # Finalize response with the same processing as Route#call
      # @param res [Rack::Response] Response object
      # @return [Array] Rack response array
      def finalize_response(res)
        res.body = [res.body] unless res.body.respond_to?(:each)
        res.finish
      end

      # Handle response using appropriate response handler
      # @param result [Object] Result from route execution
      # @param response [Rack::Response] Response object
      # @param context [Hash] Additional context for response handling
      def handle_response(result, response, context = {})
        response_type = route_definition.response_type

        # Get the appropriate response handler
        handler_class = case response_type
                        in 'json' then Otto::ResponseHandlers::JSONHandler
                        in 'redirect' then Otto::ResponseHandlers::RedirectHandler
                        in 'view' then Otto::ResponseHandlers::ViewHandler
                        in 'auto' then Otto::ResponseHandlers::AutoHandler
                        else Otto::ResponseHandlers::DefaultHandler
                        end

        handler_class.handle(result, response, context)
      end

      private

      # Safely get a constant from a string name
      # @param name [String] Class name
      # @return [Class] The class
      def safe_const_get(name)
        name.split('::').inject(Object) do |scope, const_name|
          scope.const_get(const_name)
        end
      rescue NameError => e
        raise NameError, "Unknown class: #{name} (#{e})"
      end
    end
  end
end
