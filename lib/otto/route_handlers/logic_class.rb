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
    # - params: Merged request parameters. Path captures win over the query
    #   string, which wins over the form body, which wins over a JSON body.
    # - locale: The locale string from env['otto.locale']
    #
    # IMPORTANT: Logic classes do NOT receive the Rack request or env hash.
    # This is intentional - Logic classes work with clean, authenticated contexts.
    # For endpoints requiring direct request access (sessions, cookies, headers,
    # or logout flows), use controller handlers (Controller#action or Controller.action).
    class LogicClassHandler < BaseHandler
      protected

      # Invoke Logic class with constrained signature
      # @param req [Rack::Request] Request object
      # @param res [Rack::Response] Response object
      # @return [Array] [result, context] for handle_response
      def invoke_target(req, _res)
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
      #
      # Precedence, highest first: path captures, query string, form body,
      # JSON body. A key in the request body can never replace the value the
      # router matched from the path, and a body cannot replace the query
      # string either. JSON bodies are only read for methods that carry a
      # body (never GET or HEAD).
      #
      # @param req [Rack::Request] Request object
      # @param env [Hash] Rack environment
      # @return [Hash] Parameters for Logic class
      def extract_logic_params(req, env)
        json_params = {}
        json_params = parse_json_body(req, env) if json_body?(req)

        path_params = @extra_params || {}

        # Lowest precedence first; each merge lets the later source win.
        merged = json_params.merge(stringify_keys(req.POST))
        merged = merged.merge(stringify_keys(req.GET))
        merged = merged.merge(stringify_keys(path_params))

        Otto::Static.indifferent_params(merged)
      end

      # Whether the request carries a JSON body worth parsing
      # @param req [Rack::Request] Request object
      # @return [Boolean]
      def json_body?(req)
        return false if req.get? || req.head?
        return false unless req.content_type&.include?('application/json')

        req.body&.size&.positive? || false
      end

      # Parse JSON request body with error handling
      # @param req [Rack::Request] Request object
      # @param env [Hash] Rack environment
      # @return [Hash] Parsed JSON object, or an empty hash when the body is
      #   not a JSON object or fails to parse
      def parse_json_body(req, env)
        req.body.rewind
        json_data = JSON.parse(req.body.read)
        json_data.is_a?(Hash) ? json_data : {}
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

        {}
      end

      # Normalize top-level keys to strings so sources merge on the same key
      # @param hash [Hash, nil]
      # @return [Hash]
      def stringify_keys(hash)
        return {} unless hash.is_a?(Hash)

        hash.transform_keys(&:to_s)
      end

      # Format handler name for Logic routes
      # @return [String] Handler name in format "ClassName#call"
      def handler_name
        "#{target_class.name}#call"
      end
    end
  end
end
