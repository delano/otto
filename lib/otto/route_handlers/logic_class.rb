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
    # - params: Merged request parameters. Path captures win over form and
    #   query parameters (Rack order between those two), and a JSON body sits
    #   below all of them.
    # - locale: The locale string from env['otto.locale']
    #
    # A Logic class may also declare a +route_params:+ keyword on initialize
    # to receive the path captures on their own, separate from anything the
    # caller sent in the query string or body:
    #
    #   def initialize(context, params, locale, route_params: {})
    #
    # IMPORTANT: Logic classes do NOT receive the Rack request or env hash.
    # This is intentional - Logic classes work with clean, authenticated contexts.
    # For endpoints requiring direct request access (sessions, cookies, headers,
    # or logout flows), use controller handlers (Controller#action or Controller.action).
    class LogicClassHandler < BaseHandler
      # Parameter types (from Method#parameters) that name a keyword argument
      ROUTE_PARAMS_KEYWORD_TYPES = %i[key keyreq].freeze

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

        # Instantiate Logic class. Path captures travel separately so a Logic
        # class can read the router's value by name, whatever the body sent.
        logic = if accepts_route_params?
                  target_class.new(strategy_result, logic_params, locale, route_params: route_params)
                else
                  target_class.new(strategy_result, logic_params, locale)
                end

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

      # Path captures matched by the router, keyed by the route's placeholder
      # names. Always present in +params+ as well (where they take precedence);
      # this copy is for Logic classes that must not confuse a path value with
      # one the caller put in the query string or body.
      #
      # @return [Hash] Indifferent hash of route captures; empty for literal routes
      def route_params
        Otto::Static.indifferent_params((@extra_params || {}).dup)
      end

      # Whether the Logic class constructor declares a +route_params:+ keyword
      # (or accepts arbitrary keywords). Logic classes opt in by declaring it;
      # the three-positional signature keeps working unchanged.
      #
      # @return [Boolean]
      def accepts_route_params?
        return @accepts_route_params if defined?(@accepts_route_params)

        @accepts_route_params = target_class.instance_method(:initialize).parameters.any? do |type, name|
          type == :keyrest || (ROUTE_PARAMS_KEYWORD_TYPES.include?(type) && name == :route_params)
        end
      end

      # Extract logic parameters including JSON body parsing
      #
      # Starts from req.params, which already carries Rack's own precedence
      # (form body over query string) with the path captures merged on top by
      # setup_request_response. A JSON body sits below all of those: a JSON
      # key can never replace a path capture, a query parameter, or a form
      # field. JSON bodies are only read for methods that carry a body (never
      # GET or HEAD).
      #
      # @param req [Rack::Request] Request object
      # @param env [Hash] Rack environment
      # @return [Hash] Parameters for Logic class
      def extract_logic_params(req, env)
        logic_params = req.params.dup
        return logic_params unless json_body?(req)

        json_params = parse_json_body(req, env)
        return logic_params if json_params.empty?

        Otto::Static.indifferent_params(json_params.merge(logic_params))
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

      # Format handler name for Logic routes
      # @return [String] Handler name in format "ClassName#call"
      def handler_name
        "#{target_class.name}#call"
      end
    end
  end
end
