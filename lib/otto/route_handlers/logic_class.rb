# lib/otto/route_handlers/logic_class.rb
#
# frozen_string_literal: true

require_relative 'base'

class Otto
  module RouteHandlers
    # Handler for Logic classes (new in Otto Framework Enhancement)
    #
    # Logic classes use a constrained signature: initialize(context, params, locale)
    # - context: The authentication strategy result (user info, session data)
    # - params: Merged request parameters (URL params + body + extra_params)
    # - locale: The locale string from env['otto.locale']
    #
    # IMPORTANT: Logic classes do NOT receive the Rack request or env hash.
    # This is intentional - Logic classes work with clean, authenticated contexts.
    # For endpoints requiring direct request access (sessions, cookies, headers,
    # or logout flows), use controller handlers (Controller#action or Controller.action).
    class LogicClassHandler < BaseHandler
      # Override call to store start_time for JSON parsing error logging
      def call(env, extra_params = {})
        @start_time = Otto::Utils.now_in_μs
        super
      end

      protected

      # Invoke Logic class with constrained signature
      # @param req [Rack::Request] Request object
      # @param res [Rack::Response] Response object
      # @return [Array] [result, context] for handle_response
      def invoke_target(req, res)
        env = req.env

        # Get strategy result (guaranteed to exist from RouteAuthWrapper)
        strategy_result = env['otto.strategy_result']

        # Extract params including JSON body parsing
        logic_params = extract_logic_params(req, env)

        # Get locale
        locale = env['otto.locale'] || 'en'

        # Instantiate Logic class
        logic = target_class.new(strategy_result, logic_params, locale)

        # Execute standard Logic class lifecycle
        logic.raise_concerns if logic.respond_to?(:raise_concerns)

        result = if logic.respond_to?(:process)
                   logic.process
                 else
                   logic.call || logic
                 end

        context = {
          logic_instance: logic,
          request: req,
          status_code: logic.respond_to?(:status_code) ? logic.status_code : nil,
        }

        [result, context]
      end

      # Extract logic parameters including JSON body parsing
      # @param req [Rack::Request] Request object
      # @param env [Hash] Rack environment
      # @return [Hash] Parameters for Logic class
      def extract_logic_params(req, env)
        # req.params already has extra_params merged and indifferent_params applied
        # by setup_request_response in BaseHandler
        logic_params = req.params.dup

        # Handle JSON request bodies
        if req.content_type&.include?('application/json') && req.body.size.positive?
          logic_params = parse_json_body(req, env, logic_params)
        end

        logic_params
      end

      # Parse JSON request body with error handling
      # @param req [Rack::Request] Request object
      # @param env [Hash] Rack environment
      # @param logic_params [Hash] Current parameters
      # @return [Hash] Parameters with JSON merged (or original if parsing fails)
      def parse_json_body(req, env, logic_params)
        begin
          req.body.rewind
          json_data = JSON.parse(req.body.read)
          logic_params = logic_params.merge(json_data) if json_data.is_a?(Hash)
        rescue JSON::ParserError => e
          # Base context pattern: create once, reuse for correlation
          log_context = Otto::LoggingHelpers.request_context(env)

          Otto.structured_log(:error, 'JSON parsing error',
            log_context.merge(
              handler: handler_name,
              error: e.message,
              error_class: e.class.name,
              duration: Otto::Utils.now_in_μs - @start_time
            ))

          Otto::LoggingHelpers.log_backtrace(e,
            log_context.merge(handler: handler_name))
        end

        logic_params
      end

      # Format handler name for Logic routes
      # @return [String] Handler name in format "ClassName#call"
      def handler_name
        "#{target_class.name}#call"
      end
    end
  end
end
