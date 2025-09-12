# frozen_string_literal: true

# lib/otto/route_handlers.rb
require 'json'

class Otto
  # Pluggable Route Handler Factory (Phase 4)
  # Enables different execution patterns while maintaining backward compatibility
  module RouteHandlers
    # Factory for creating appropriate handlers based on route definitions
    class HandlerFactory
      # Create a handler for the given route definition
      # @param route_definition [Otto::RouteDefinition] The route definition
      # @param otto_instance [Otto] The Otto instance for configuration access
      # @return [BaseHandler] Appropriate handler for the route
      def self.create_handler(route_definition, otto_instance = nil)
        case route_definition.kind
        when :logic
          LogicClassHandler.new(route_definition, otto_instance)
        when :instance
          InstanceMethodHandler.new(route_definition, otto_instance)
        when :class
          ClassMethodHandler.new(route_definition, otto_instance)
        else
          raise ArgumentError, "Unknown handler kind: #{route_definition.kind}"
        end
      end
    end

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

    # Handler for Logic classes (new in Otto Framework Enhancement)
    # Handles Logic class routes with the modern RequestContext pattern
    # Logic classes use signature: initialize(context, params, locale)
    class LogicClassHandler < BaseHandler
      def call(env, extra_params = {})
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          # Get strategy result (guaranteed to exist from auth middleware)
          strategy_result = env['otto.strategy_result'] || Otto::StrategyResult.anonymous

          # Initialize Logic class with new signature: context, params, locale
          logic_params = req.params.merge(extra_params)

          # Handle JSON request bodies
          if req.content_type&.include?('application/json') && req.body.size > 0
            begin
              req.body.rewind
              json_data = JSON.parse(req.body.read)
              logic_params = logic_params.merge(json_data) if json_data.is_a?(Hash)
            rescue JSON::ParserError => e
              Otto.logger.error "[LogicClassHandler] JSON parsing error: #{e.message}"
            end
          end

          locale = env['otto.locale'] || 'en'

          logic = target_class.new(strategy_result, logic_params, locale)

          # Execute standard Logic class lifecycle
          logic.raise_concerns if logic.respond_to?(:raise_concerns)

          result = if logic.respond_to?(:process)
                     logic.process
                   else
                     logic.call || logic
                   end

          # Handle response with Logic instance context
          handle_response(result, res, {
                            logic_instance: logic,
            request: req,
            status_code: logic.respond_to?(:status_code) ? logic.status_code : nil,
                          })

        rescue StandardError => e
          # Check if we're being called through Otto's integrated context (vs direct handler testing)
          # In integrated context, let Otto's centralized error handler manage the response
          # In direct testing context, handle errors locally for unit testing
          if otto_instance
            # Log error for handler-specific context but let Otto's centralized error handler manage the response
            Otto.logger.error "[LogicClassHandler] #{e.class}: #{e.message}"
            Otto.logger.debug "[LogicClassHandler] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug
            raise e # Re-raise to let Otto's centralized error handler manage the response
          else
            # Direct handler testing context - handle errors locally with security improvements
            error_id = SecureRandom.hex(8)
            Otto.logger.error "[#{error_id}] #{e.class}: #{e.message}"
            Otto.logger.debug "[#{error_id}] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug

            res.status                  = 500
            res.headers['content-type'] = 'text/plain'

            if Otto.env?(:dev, :development)
              res.write "Server error (ID: #{error_id}). Check logs for details."
            else
              res.write 'An error occurred. Please try again later.'
            end

            # Add security headers if available
            if otto_instance.respond_to?(:security_config) && otto_instance.security_config
              otto_instance.security_config.security_headers.each do |header, value|
                res.headers[header] = value
              end
            end
          end
        end

        res.finish
      end
    end

    # Handler for instance methods (existing Otto pattern)
    # Maintains backward compatibility for Controller#action patterns
    class InstanceMethodHandler < BaseHandler
      def call(env, extra_params = {})
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          # Apply the same extensions and processing as original Route#call
          setup_request_response(req, res, env, extra_params)

          # Create instance and call method (existing Otto behavior)
          instance = target_class.new(req, res)
          result   = instance.send(route_definition.method_name)

          # Only handle response if response_type is not default
          if route_definition.response_type != 'default'
            handle_response(result, res, {
                              instance: instance,
              request: req,
                            })
          end
        rescue StandardError => e
          # Check if we're being called through Otto's integrated context (vs direct handler testing)
          # In integrated context, let Otto's centralized error handler manage the response
          # In direct testing context, handle errors locally for unit testing
          if otto_instance
            # Log error for handler-specific context but let Otto's centralized error handler manage the response
            Otto.logger.error "[InstanceMethodHandler] #{e.class}: #{e.message}"
            Otto.logger.debug "[InstanceMethodHandler] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug
            raise e # Re-raise to let Otto's centralized error handler manage the response
          else
            # Direct handler testing context - handle errors locally with security improvements
            error_id = SecureRandom.hex(8)
            Otto.logger.error "[#{error_id}] #{e.class}: #{e.message}"
            Otto.logger.debug "[#{error_id}] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug

            res.status                  = 500
            res.headers['content-type'] = 'text/plain'

            if Otto.env?(:dev, :development)
              res.write "Server error (ID: #{error_id}). Check logs for details."
            else
              res.write 'An error occurred. Please try again later.'
            end

            # Add security headers if available
            if otto_instance.respond_to?(:security_config) && otto_instance.security_config
              otto_instance.security_config.security_headers.each do |header, value|
                res.headers[header] = value
              end
            end
          end
        end

        finalize_response(res)
      end
    end

    # Handler for class methods (existing Otto pattern)
    # Maintains backward compatibility for Controller.action patterns
    class ClassMethodHandler < BaseHandler
      def call(env, extra_params = {})
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          # Apply the same extensions and processing as original Route#call
          setup_request_response(req, res, env, extra_params)

          # Call class method directly (existing Otto behavior)
          result = target_class.send(route_definition.method_name, req, res)

          # Only handle response if response_type is not default
          if route_definition.response_type != 'default'
            handle_response(result, res, {
                              class: target_class,
              request: req,
                            })
          end
        rescue StandardError => e
          # Check if we're being called through Otto's integrated context (vs direct handler testing)
          # In integrated context, let Otto's centralized error handler manage the response
          # In direct testing context, handle errors locally for unit testing
          if otto_instance
            # Log error for handler-specific context but let Otto's centralized error handler manage the response
            Otto.logger.error "[ClassMethodHandler] #{e.class}: #{e.message}"
            Otto.logger.debug "[ClassMethodHandler] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug
            raise e # Re-raise to let Otto's centralized error handler manage the response
          else
            # Direct handler testing context - handle errors locally with security improvements
            error_id = SecureRandom.hex(8)
            Otto.logger.error "[#{error_id}] #{e.class}: #{e.message}"
            Otto.logger.debug "[#{error_id}] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug

            res.status = 500

            # Content negotiation for error response
            accept_header = env['HTTP_ACCEPT'].to_s
            if accept_header.include?('application/json')
              res.headers['content-type'] = 'application/json'
              error_data                  = if Otto.env?(:dev, :development)
                                              {
                                                error: 'Internal Server Error',
                                                message: 'Server error occurred. Check logs for details.',
                                                error_id: error_id,
                                              }
                                            else
                                              {
                                                error: 'Internal Server Error',
                                                message: 'An error occurred. Please try again later.',
                                              }
                                            end
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
        end

        finalize_response(res)
      end
    end

    # Custom handler for lambda/proc definitions (future extension)
    class LambdaHandler < BaseHandler
      def call(env, extra_params = {})
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          # Security: Lambda handlers require pre-configured procs from Otto instance
          # This prevents code injection via eval and maintains security
          handler_name    = route_definition.klass_name
          lambda_registry = otto_instance&.config&.dig(:lambda_handlers) || {}

          lambda_proc = lambda_registry[handler_name]
          unless lambda_proc.respond_to?(:call)
            raise ArgumentError, "Lambda handler '#{handler_name}' not found in registry or not callable"
          end

          result = lambda_proc.call(req, res, extra_params)

          handle_response(result, res, {
                            lambda: lambda_proc,
            request: req,
                          })
        rescue StandardError => e
          error_id = SecureRandom.hex(8)
          Otto.logger.error "[#{error_id}] #{e.class}: #{e.message}"
          Otto.logger.debug "[#{error_id}] Backtrace: #{e.backtrace.join("\n")}" if Otto.debug

          res.status                  = 500
          res.headers['content-type'] = 'text/plain'

          if Otto.env?(:dev, :development)
            res.write "Lambda handler error (ID: #{error_id}). Check logs for details."
          else
            res.write 'An error occurred. Please try again later.'
          end

          # Add security headers if available
          if otto_instance.respond_to?(:security_config) && otto_instance.security_config
            otto_instance.security_config.security_headers.each do |header, value|
              res.headers[header] = value
            end
          end
        end

        res.finish
      end
    end
  end
end
