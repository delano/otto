# frozen_string_literal: true

# lib/otto/security/authentication/route_auth_wrapper.rb

class Otto
  module Security
    module Authentication
      # Wraps route handlers to enforce authentication requirements
      #
      # This wrapper executes authentication strategies AFTER routing but BEFORE
      # route handler execution. This solves the architectural issue where
      # middleware-based authentication runs before routing (so can't access route info).
      #
      # Flow:
      #   1. Route matched (route_definition available)
      #   2. RouteAuthWrapper#call invoked
      #   3. Execute auth strategy based on route's auth_requirement
      #   4. Set env['otto.strategy_result'], env['otto.user']
      #   5. If auth fails, return 401 or redirect
      #   6. If auth succeeds, call wrapped handler
      #
      # @example
      #   handler = InstanceMethodHandler.new(route_def, otto)
      #   wrapped = RouteAuthWrapper.new(handler, route_def, auth_config)
      #   wrapped.call(env, extra_params)
      #
      class RouteAuthWrapper
        attr_reader :wrapped_handler, :route_definition, :auth_config

        def initialize(wrapped_handler, route_definition, auth_config)
          @wrapped_handler  = wrapped_handler
          @route_definition = route_definition
          @auth_config      = auth_config  # Hash: { auth_strategies: {}, default_auth_strategy: 'publicly' }
        end

        # Execute authentication then call wrapped handler
        #
        # @param env [Hash] Rack environment
        # @param extra_params [Hash] Additional parameters
        # @return [Array] Rack response array
        def call(env, extra_params = {})
          # Execute authentication strategy for this route
          auth_requirement = route_definition.auth_requirement
          strategy = get_strategy(auth_requirement)

          unless strategy
            Otto.logger.error "[RouteAuthWrapper] No strategy found for requirement: #{auth_requirement}"
            return unauthorized_response(env, "Authentication strategy not configured")
          end

          # Execute the strategy
          result = strategy.authenticate(env, auth_requirement)

          # Set environment variables for controllers/logic
          env['otto.strategy_result'] = result
          env['otto.user'] = result.user if result.is_a?(StrategyResult)
          env['otto.user_context'] = result.user_context if result.is_a?(StrategyResult)

          # Handle authentication failure
          if result.is_a?(FailureResult)
            return auth_failure_response(env, result)
          end

          # Authentication succeeded - call wrapped handler
          wrapped_handler.call(env, extra_params)
        end

        private

        # Get strategy from auth_config hash
        #
        # @param requirement [String] Auth requirement from route
        # @return [AuthStrategy, nil] Strategy instance or nil
        def get_strategy(requirement)
          return nil unless auth_config && auth_config[:auth_strategies]

          auth_config[:auth_strategies][requirement]
        end

        # Generate 401 response for authentication failure
        #
        # @param env [Hash] Rack environment
        # @param result [FailureResult] Failure result from strategy
        # @return [Array] Rack response array
        def auth_failure_response(env, result)
          # Check if request wants JSON
          accept_header = env['HTTP_ACCEPT'] || ''
          wants_json = accept_header.include?('application/json')

          if wants_json
            json_auth_error(result)
          else
            html_auth_error(result)
          end
        end

        # Generate JSON 401 response
        #
        # @param result [FailureResult] Failure result
        # @return [Array] Rack response array
        def json_auth_error(result)
          body = {
            error: 'Authentication Required',
            message: result.message || 'Not authenticated',
            timestamp: Time.now.to_i
          }.to_json

          [
            401,
            { 'content-type' => 'application/json' },
            [body]
          ]
        end

        # Generate HTML 401 response or redirect
        #
        # @param result [FailureResult] Failure result
        # @return [Array] Rack response array
        def html_auth_error(result)
          # For HTML requests, redirect to login
          login_path = auth_config[:login_path] || '/signin'

          [
            302,
            { 'location' => login_path },
            ["Redirecting to #{login_path}"]
          ]
        end

        # Generate generic unauthorized response
        #
        # @param env [Hash] Rack environment
        # @param message [String] Error message
        # @return [Array] Rack response array
        def unauthorized_response(env, message)
          accept_header = env['HTTP_ACCEPT'] || ''
          wants_json = accept_header.include?('application/json')

          if wants_json
            body = { error: message }.to_json
            [401, { 'content-type' => 'application/json' }, [body]]
          else
            [401, { 'content-type' => 'text/plain' }, [message]]
          end
        end
      end
    end
  end
end
