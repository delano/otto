# frozen_string_literal: true

# lib/otto/route_handlers/logic_class.rb
require 'json'
require 'securerandom'

require_relative 'base'

class Otto
  module RouteHandlers
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
          if req.content_type&.include?('application/json') && req.body.size.positive?
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
  end
end
