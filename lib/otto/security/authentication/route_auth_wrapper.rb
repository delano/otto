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
      # - Supports multi-strategy with OR logic (first authenticated success wins)
      # - Performs Layer 1 (route-level) role authorization
      #
      # Multi-strategy chain semantics (in precedence order):
      # - AUTHENTICATED success wins immediately; later strategies never run.
      # - TERMINAL failure (AuthFailure with terminal: true — explicit
      #   credentials examined and rejected) halts the chain and fails closed,
      #   regardless of strategy order. An anonymous success from an
      #   anonymous-capable strategy elsewhere in the chain does not rescue the
      #   request. See AuthFailure.
      # - ANONYMOUS success (StrategyResult with no user, e.g. from noauth) is
      #   held as a fallback while the rest of the chain runs. It wins once the
      #   chain completes without an authenticated success or terminal failure,
      #   so credential-less requests still fall through to noauth.
      # - Plain failures are recorded and the next strategy is consulted
      #   (OR logic). If everything fails, an AuthorizationFailure (valid
      #   credential, denied) yields 403; otherwise 401.
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

          # Try each strategy in order (first authenticated success wins;
          # anonymous success is a fallback; terminal failure halts the chain)
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
          anonymous_fallback = nil
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

            # Handle authenticated success - wins immediately
            if authenticated_result?(result)
              return handle_auth_success(env, extra_params, result, strategy_name,
                                        duration, total_start_time, failed_strategies)
            end

            # An anonymous success (e.g. noauth) is held as a fallback rather
            # than winning outright, so a credentialed strategy elsewhere in
            # the chain still gets to examine explicitly presented credentials
            # and reject them terminally, regardless of declaration order.
            # When the chain completes without a terminal failure, the
            # fallback wins (see below), preserving OR fallthrough for
            # credential-less requests.
            if anonymous_result?(result)
              anonymous_fallback ||= { result: result, strategy_name: strategy_name, duration: duration }
              next
            end

            # Handle a failure (authentication OR authorization) - record it and
            # continue to the next strategy (OR logic; a later success still wins).
            # AuthorizationFailure (valid credential, denied) is tagged so the
            # final response is 403 instead of 401. See handle_all_strategies_failed.
            next unless result.is_a?(AuthFailure) || result.is_a?(AuthorizationFailure)

            log_strategy_failure(env, strategy_name, result, duration, auth_requirements, requirement)

            # A terminal failure means explicit credentials were examined and
            # rejected: fail the whole chain closed (401) instead of letting an
            # anonymous-capable strategy accept the request as anonymous.
            if record_failure(failed_strategies, strategy_name, result)
              return handle_all_strategies_failed(env, auth_requirements, failed_strategies,
                                                  total_start_time, terminal: true)
            end
          end

          # Chain completed without authenticated success or terminal failure:
          # a held anonymous success wins (OR fallthrough to noauth et al.)
          if anonymous_fallback
            return handle_auth_success(env, extra_params, anonymous_fallback[:result],
                                       anonymous_fallback[:strategy_name],
                                       anonymous_fallback[:duration],
                                       total_start_time, failed_strategies)
          end

          # All strategies failed
          handle_all_strategies_failed(env, auth_requirements, failed_strategies, total_start_time)
        end

        def authenticated_result?(result)
          result.is_a?(StrategyResult) && result.authenticated?
        end

        def anonymous_result?(result)
          result.is_a?(StrategyResult) && result.anonymous?
        end

        # Append the failure to the running list; returns true when it was terminal
        def record_failure(failed_strategies, strategy_name, result)
          terminal = result.is_a?(AuthFailure) && result.terminal?
          failed_strategies << {
            strategy: strategy_name,
            reason: result.failure_reason,
            authorization: result.is_a?(AuthorizationFailure),
            terminal: terminal,
          }
          terminal
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

        # Handle case when authentication fails for the whole chain — either
        # every strategy failed, or a terminal failure halted the chain early
        # (terminal: true; remaining strategies were deliberately not consulted).
        def handle_all_strategies_failed(env, auth_requirements, failed_strategies, total_start_time, terminal: false)
          total_duration = Otto::Utils.now_in_μs - total_start_time

          log_all_failed(env, failed_strategies, total_duration, terminal: terminal)

          # Create anonymous result with failure info
          metadata = build_failure_metadata(env, failed_strategies, terminal: terminal)
          failure_strategy_name = determine_failure_strategy_name(auth_requirements, failed_strategies)

          env['otto.strategy_result'] = StrategyResult.anonymous(
            metadata: metadata,
            strategy_name: failure_strategy_name
          )

          # Authorization denial wins over authentication failure: if any strategy
          # authenticated the subject but denied authorization (wrong role/missing
          # permission), respond 403 Forbidden rather than 401 — the subject IS
          # authenticated, they simply lack access. A bare 401 would (incorrectly)
          # tell a logged-in client to re-authenticate. This precedence also holds
          # on a terminal halt: the denial's 403 is the more specific outcome.
          authz_denial = failed_strategies.find { |f| f[:authorization] }
          return @response_builder.forbidden(env, authz_denial[:reason]) if authz_denial

          # On a terminal halt the terminal failure is necessarily the last one
          # recorded, so its reason is what gets rendered.
          last_failure = if failed_strategies.any?
                           AuthFailure.new(
                             failure_reason: failed_strategies.last[:reason],
                             auth_method: failed_strategies.last[:strategy],
                             terminal: failed_strategies.last[:terminal] || false
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
          metadata = { ip: env['otto.client_ip'] || env['REMOTE_ADDR'] }
          metadata[:country] = env['otto.privacy.geo_country'] if env['otto.privacy.geo_country']
          metadata
        end

        # Build metadata for failed authentication
        def build_failure_metadata(env, failed_strategies, terminal: false)
          failure_summary = if terminal
                              'Authentication halted by terminal failure'
                            else
                              'All authentication strategies failed'
                            end
          metadata = {
                          ip: env['otto.client_ip'] || env['REMOTE_ADDR'],
                auth_failure: failure_summary,
            attempted_strategies: failed_strategies.map { |f| f[:strategy] },
                 failure_reasons: failed_strategies.map { |f| f[:reason] },
          }
          metadata[:terminal_failure] = true if terminal
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

        def log_all_failed(env, failed_strategies, total_duration, terminal: false)
          message = terminal ? 'Auth chain halted by terminal failure' : 'All auth strategies failed'
          Otto.structured_log(:warn, message,
            Otto::LoggingHelpers.request_context(env).merge(
              strategies_attempted: failed_strategies.map { |f| f[:strategy] },
              total_duration: total_duration,
              failure_count: failed_strategies.size,
              terminal: terminal
            ))
        end
      end
    end
  end
end
