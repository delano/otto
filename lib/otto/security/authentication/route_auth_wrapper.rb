# frozen_string_literal: true

require_relative 'route_auth_wrapper/strategy_resolver'
require_relative 'route_auth_wrapper/response_builder'
require_relative 'route_auth_wrapper/role_authorization'

class Otto
  module Security
    module Authentication
      # Wraps route handlers with authentication and authorization
      #
      # This is the main orchestrator that:
      # - Sets anonymous StrategyResult for unauthenticated routes
      # - Enforces authentication for protected routes
      # - Supports multi-strategy with OR logic (first success wins)
      # - Performs Layer 1 (route-level) role authorization
      #
      # @example Basic usage
      #   wrapper = RouteAuthWrapper.new(handler, route_def, auth_config)
      #   response = wrapper.call(env)
      #
      # @see RouteAuthWrapper::StrategyResolver for strategy lookup
      # @see RouteAuthWrapper::ResponseBuilder for error responses
      # @see RouteAuthWrapper::RoleAuthorization for role checking
      #
      class RouteAuthWrapper
        attr_reader :wrapped_handler, :route_definition, :auth_config, :security_config

        def initialize(wrapped_handler, route_definition, auth_config, security_config = nil)
          @wrapped_handler  = wrapped_handler
          @route_definition = route_definition
          @auth_config      = auth_config
          @security_config  = security_config

          # Initialize extracted components
          @strategy_resolver = RouteAuthWrapperComponents::StrategyResolver.new(auth_config)
          @response_builder  = RouteAuthWrapperComponents::ResponseBuilder.new(route_definition, auth_config, security_config)
          @role_authorizer   = RouteAuthWrapperComponents::RoleAuthorization.new(route_definition)
        end

        # Execute authentication then call wrapped handler
        #
        # @param env [Hash] Rack environment
        # @param extra_params [Hash] Additional parameters
        # @return [Array] Rack response array
        def call(env, extra_params = {})
          auth_requirements = route_definition.auth_requirements

          # Routes without auth requirement get anonymous StrategyResult
          return handle_anonymous_route(env, extra_params) if auth_requirements.empty?

          # Validate all strategies exist before executing any (fail-fast)
          validation_error = validate_strategies(auth_requirements, env)
          return validation_error if validation_error

          # Try each strategy in order (first success wins)
          authenticate_and_authorize(env, extra_params, auth_requirements)
        end

        private

        # Handle routes without authentication requirements
        def handle_anonymous_route(env, extra_params)
          metadata = build_anonymous_metadata(env)
          result = StrategyResult.anonymous(metadata: metadata, strategy_name: 'anonymous')
          env['otto.strategy_result'] = result
          wrapped_handler.call(env, extra_params)
        end

        # Validate all strategies exist before executing
        #
        # @return [Array, nil] Error response if validation fails, nil otherwise
        def validate_strategies(auth_requirements, env)
          auth_requirements.each do |requirement|
            strategy, _name = @strategy_resolver.resolve(requirement)
            next if strategy

            error_msg = "Authentication strategy not configured: '#{requirement}'"
            Otto.logger.error "[RouteAuthWrapper] #{error_msg}"
            return @response_builder.unauthorized(env, error_msg)
          end
          nil
        end

        # Main authentication and authorization flow
        def authenticate_and_authorize(env, extra_params, auth_requirements)
          failed_strategies = []
          total_start_time = Otto::Utils.now_in_μs

          auth_requirements.each do |requirement|
            strategy, strategy_name = @strategy_resolver.resolve(requirement)

            log_strategy_start(env, strategy_name, requirement, auth_requirements)

            # Execute the strategy
            start_time = Otto::Utils.now_in_μs
            result = strategy.authenticate(env, requirement)
            duration = Otto::Utils.now_in_μs - start_time

            # Inject strategy_name into result
            result = result.with(strategy_name: strategy_name) if result.is_a?(StrategyResult)

            # Handle authentication success
            if result.is_a?(StrategyResult) && (result.authenticated? || result.anonymous?)
              return handle_auth_success(env, extra_params, result, strategy_name,
                                        duration, total_start_time, failed_strategies)
            end

            # Handle authentication failure - continue to next strategy
            next unless result.is_a?(AuthFailure)

            log_strategy_failure(env, strategy_name, result, duration, auth_requirements, requirement)
            failed_strategies << { strategy: strategy_name, reason: result.failure_reason }
          end

          # All strategies failed
          handle_all_strategies_failed(env, auth_requirements, failed_strategies, total_start_time)
        end

        # Handle successful authentication
        def handle_auth_success(env, extra_params, result, strategy_name, duration, total_start_time, failed_strategies)
          total_duration = Otto::Utils.now_in_μs - total_start_time

          log_auth_success(env, strategy_name, result, duration, total_duration, failed_strategies)

          # Set environment variables for controllers/logic
          env['otto.strategy_result'] = result

          # SESSION PERSISTENCE: Ensure env['rack.session'] and strategy_result.session
          # reference the SAME object for proper session persistence
          env['rack.session'] = result.session if result.is_a?(StrategyResult) && result.session

          # Layer 1 Authorization: Check role requirements
          auth_check = @role_authorizer.check(result, env)
          unless auth_check == true
            return @response_builder.forbidden(env,
              "Access denied: requires one of roles: #{auth_check[:required].join(', ')}")
          end

          # Authentication and authorization succeeded
          wrapped_handler.call(env, extra_params)
        end

        # Handle case when all authentication strategies fail
        def handle_all_strategies_failed(env, auth_requirements, failed_strategies, total_start_time)
          total_duration = Otto::Utils.now_in_μs - total_start_time

          log_all_failed(env, failed_strategies, total_duration)

          # Create anonymous result with failure info
          metadata = build_failure_metadata(env, failed_strategies)
          failure_strategy_name = determine_failure_strategy_name(auth_requirements, failed_strategies)

          env['otto.strategy_result'] = StrategyResult.anonymous(
            metadata: metadata,
            strategy_name: failure_strategy_name
          )

          last_failure = if failed_strategies.any?
                           AuthFailure.new(
                             failure_reason: failed_strategies.last[:reason],
                             auth_method: failed_strategies.last[:strategy]
                           )
                         else
                           AuthFailure.new(
                             failure_reason: 'Authentication required',
                             auth_method: auth_requirements.first
                           )
                         end

          @response_builder.auth_failure(env, last_failure)
        end

        # Build metadata for anonymous routes
        def build_anonymous_metadata(env)
          metadata = { ip: env['REMOTE_ADDR'] }
          metadata[:country] = env['otto.privacy.geo_country'] if env['otto.privacy.geo_country']
          metadata
        end

        # Build metadata for failed authentication
        def build_failure_metadata(env, failed_strategies)
          metadata = {
                          ip: env['REMOTE_ADDR'],
                auth_failure: 'All authentication strategies failed',
            attempted_strategies: failed_strategies.map { |f| f[:strategy] },
                 failure_reasons: failed_strategies.map { |f| f[:reason] },
          }
          metadata[:country] = env['otto.privacy.geo_country'] if env['otto.privacy.geo_country']
          metadata
        end

        # Determine strategy name for failure response
        def determine_failure_strategy_name(auth_requirements, failed_strategies)
          if auth_requirements.size > 1
            'multi-strategy-failure'
          elsif failed_strategies.any?
            failed_strategies.first[:strategy]
          else
            auth_requirements.first
          end
        end

        # Logging helpers

        def log_strategy_start(env, strategy_name, requirement, auth_requirements)
          Otto.structured_log(:debug, 'Auth strategy executing',
            Otto::LoggingHelpers.request_context(env).merge(
              strategy: strategy_name,
              requirement: requirement,
              strategy_position: auth_requirements.index(requirement) + 1,
              total_strategies: auth_requirements.size
            ))
        end

        def log_auth_success(env, strategy_name, result, duration, total_duration, failed_strategies)
          Otto.structured_log(:info, 'Auth strategy result',
            Otto::LoggingHelpers.request_context(env).merge(
              strategy: strategy_name,
              success: true,
              user_id: result.user_id,
              duration: duration,
              total_duration: total_duration,
              strategies_attempted: failed_strategies.size + 1
            ))
        end

        def log_strategy_failure(env, strategy_name, result, duration, auth_requirements, requirement)
          Otto.structured_log(:info, 'Auth strategy result',
            Otto::LoggingHelpers.request_context(env).merge(
              strategy: strategy_name,
              success: false,
              failure_reason: result.failure_reason,
              duration: duration,
              remaining_strategies: auth_requirements.size - auth_requirements.index(requirement) - 1
            ))
        end

        def log_all_failed(env, failed_strategies, total_duration)
          Otto.structured_log(:warn, 'All auth strategies failed',
            Otto::LoggingHelpers.request_context(env).merge(
              strategies_attempted: failed_strategies.map { |f| f[:strategy] },
              total_duration: total_duration,
              failure_count: failed_strategies.size
            ))
        end
      end
    end
  end
end
