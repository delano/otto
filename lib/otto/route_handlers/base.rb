# lib/otto/route_handlers/base.rb
#
# frozen_string_literal: true

require 'json'
require 'securerandom'

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
        start_time = Otto::Utils.now_in_μs
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          setup_request_response(req, res, env, extra_params)
          result, context = invoke_target(req, res)

          if route_definition.response_type != 'default'
            handle_response(result, res, context)
          end
        rescue StandardError => e
          handle_execution_error(e, env, req, res, start_time)
        end

        finalize_response(res)
      end

      protected

      # Get the target class, loading it safely
      # @return [Class] The target class
      def target_class
        @target_class ||= safe_const_get(route_definition.klass_name)
      end

      # Template method for subclasses to implement their invocation logic
      # @param req [Rack::Request] Request object
      # @param res [Rack::Response] Response object
      # @return [Array] [result, context] where context is a hash for handle_response
      def invoke_target(req, res)
        raise NotImplementedError, 'Subclasses must implement #invoke_target'
      end

      # Handle errors during route execution
      # @param error [StandardError] The error that occurred
      # @param env [Hash] Rack environment
      # @param req [Rack::Request] Request object
      # @param res [Rack::Response] Response object
      # @param start_time [Integer] Start time in microseconds
      def handle_execution_error(error, env, req, res, start_time)
        if otto_instance
          # Integrated context - let centralized error handler manage
          env['otto.handler'] = handler_name
          env['otto.handler_duration'] = Otto::Utils.now_in_μs - start_time
          raise error
        else
          # Direct testing context - handle locally
          handle_local_error(error, env, res)
        end
      end

      # Handle errors locally for testing context
      # @param error [StandardError] The error that occurred
      # @param env [Hash] Rack environment
      # @param res [Rack::Response] Response object
      def handle_local_error(error, env, res)
        error_id = SecureRandom.hex(8)
        Otto.logger.error "[#{error_id}] #{error.class}: #{error.message}"
        Otto.logger.debug "[#{error_id}] Backtrace: #{error.backtrace.join("\n")}" if Otto.debug

        res.status = 500

        # Content negotiation for error response
        # Route's response_type takes precedence over Accept header
        route_def = env['otto.route_definition']
        wants_json = (route_def&.response_type == 'json') ||
                     env['HTTP_ACCEPT'].to_s.include?('application/json')

        if wants_json
          res.headers['content-type'] = 'application/json'
          error_data = {
            error: 'Internal Server Error',
            message: 'Server error occurred. Check logs for details.',
            error_id: error_id,
          }
          res.write JSON.generate(error_data)
        else
          res.headers['content-type'] = 'text/plain'
          if Otto.env?(:dev, :development)
            res.write "Server error (ID: #{error_id}). Check logs for details."
          else
            res.write 'An error occurred. Please try again later.'
          end
        end

        # Add security headers if available
        if otto_instance.respond_to?(:security_config) && otto_instance.security_config
          otto_instance.security_config.security_headers.each do |header, value|
            res.headers[header] = value
          end
        end
      end

      # Format the handler name for logging
      # @return [String] Handler name in format "ClassName#method_name"
      def handler_name
        "#{target_class.name}##{route_definition.method_name}"
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
