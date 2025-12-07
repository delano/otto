# lib/otto/route_handlers/logic_class.rb
#
# frozen_string_literal: true

require 'json'

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
      def call(env, extra_params = {})
        start_time = Otto::Utils.now_in_μs
        req = Rack::Request.new(env)
        res = Rack::Response.new

        begin
          # Get strategy result (guaranteed to exist from RouteAuthWrapper)
          strategy_result = env['otto.strategy_result']

          # Initialize Logic class with new signature: context, params, locale
          logic_params = req.params.merge(extra_params)

          # Handle JSON request bodies
          if req.content_type&.include?('application/json') && req.body.size.positive?
            begin
              req.body.rewind
              json_data = JSON.parse(req.body.read)
              logic_params = logic_params.merge(json_data) if json_data.is_a?(Hash)
            rescue JSON::ParserError => e
              # Base context pattern: create once, reuse for correlation
              log_context = Otto::LoggingHelpers.request_context(env)

              Otto.structured_log(:error, 'JSON parsing error',
                log_context.merge(
                  handler: "#{target_class}#call",
                  error: e.message,
                  error_class: e.class.name,
                  duration: Otto::Utils.now_in_μs - start_time
                ))

              Otto::LoggingHelpers.log_backtrace(e,
                log_context.merge(handler: "#{target_class}#call"))
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

          context = {
            logic_instance: logic,
                   request: req,
               status_code: logic.respond_to?(:status_code) ? logic.status_code : nil,
          }

          # Handle response with Logic instance context
          handle_response(result, res, context)
        rescue StandardError => e
          handle_execution_error(e, env, req, res, start_time)
        end

        res.finish
      end
    end
  end
end
