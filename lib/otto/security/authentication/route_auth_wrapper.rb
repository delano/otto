# lib/otto/security/authentication/route_auth_wrapper.rb
#
# frozen_string_literal: true

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
      #   4. Set env['otto.strategy_result']
      #   5. If auth fails, return 401 or redirect
      #   6. If auth succeeds, call wrapped handler
      #
      # @example
      #   handler = InstanceMethodHandler.new(route_def, otto)
      #   wrapped = RouteAuthWrapper.new(handler, route_def, auth_config)
      #   wrapped.call(env, extra_params)
      #
      class RouteAuthWrapper
        attr_reader :wrapped_handler, :route_definition, :auth_config, :security_config

        def initialize(wrapped_handler, route_definition, auth_config, security_config = nil)
          @wrapped_handler  = wrapped_handler
          @route_definition = route_definition
          @auth_config      = auth_config  # Hash: { auth_strategies: {}, default_auth_strategy: 'publicly' }
          @security_config  = security_config
          @strategy_cache   = {}  # Cache resolved strategies to avoid repeated lookups
        end

        # Execute authentication then call wrapped handler
        #
        # For routes WITHOUT auth requirement: Sets anonymous StrategyResult
        # For routes WITH auth requirement: Enforces authentication
        # Supports multi-strategy with OR logic: auth=session,apikey,oauth
        #
        # @param env [Hash] Rack environment
        # @param extra_params [Hash] Additional parameters
        # @return [Array] Rack response array
        def call(env, extra_params = {})
          auth_requirements = route_definition.auth_requirements

          # Routes without auth requirement get anonymous StrategyResult
          if auth_requirements.empty?
            # Note: env['REMOTE_ADDR'] is masked by IPPrivacyMiddleware by default
            metadata = { ip: env['REMOTE_ADDR'] }
            metadata[:country] = env['otto.privacy.geo_country'] if env['otto.privacy.geo_country']

            result = StrategyResult.anonymous(metadata: metadata, strategy_name: 'anonymous')
            env['otto.strategy_result'] = result
            return wrapped_handler.call(env, extra_params)
          end

          # Routes WITH auth requirements: Try each strategy in order (first success wins)

          # Validate all strategies exist before executing any (fail-fast)
          auth_requirements.each do |requirement|
            strategy, _strategy_name = get_strategy(requirement)
            unless strategy
              error_msg = "Authentication strategy not configured: '#{requirement}'"
              Otto.logger.error "[RouteAuthWrapper] #{error_msg}"
              return unauthorized_response(env, error_msg)
            end
          end

          last_failure = nil
          failed_strategies = []
          total_start_time = Otto::Utils.now_in_μs

          auth_requirements.each do |requirement|
            strategy, strategy_name = get_strategy(requirement)

            # Log strategy execution start
            Otto.structured_log(:debug, "Auth strategy executing",
              Otto::LoggingHelpers.request_context(env).merge(
                strategy: strategy_name,
                requirement: requirement,
                strategy_position: auth_requirements.index(requirement) + 1,
                total_strategies: auth_requirements.size
              )
            )

            # Execute the strategy
            start_time = Otto::Utils.now_in_μs
            result = strategy.authenticate(env, requirement)
            duration = Otto::Utils.now_in_μs - start_time

            # Inject strategy_name into result (Data.define objects are immutable, use #with for updates)
            if result.is_a?(StrategyResult)
              result = result.with(strategy_name: strategy_name)
            end

            # Handle authentication success - return immediately
            if result.is_a?(StrategyResult) && result.authenticated?
              total_duration = Otto::Utils.now_in_μs - total_start_time

              # Log authentication success
              Otto.structured_log(:info, "Auth strategy result",
                Otto::LoggingHelpers.request_context(env).merge(
                  strategy: strategy_name,
                  success: true,
                  user_id: result.user_id,
                  duration: duration,
                  total_duration: total_duration,
                  strategies_attempted: failed_strategies.size + 1
                )
              )

              # Set environment variables for controllers/logic on success
              env['otto.strategy_result'] = result

              # SESSION PERSISTENCE: This assignment is INTENTIONAL, not a merge operation.
              # We must ensure env['rack.session'] and strategy_result.session reference
              # the SAME object so that:
              #   1. Logic classes write to strategy_result.session
              #   2. Rack's session middleware persists env['rack.session']
              #   3. Changes from (1) are included in (2)
              #
              # Using merge! instead would break this - the objects must be identical.
              env['rack.session'] = result.session if result.is_a?(StrategyResult) && result.session

              # Layer 1 Authorization: Check role requirements (route-level)
              role_requirements = route_definition.role_requirements
              unless role_requirements.empty?
                user_roles = extract_user_roles(result)

                # OR logic: user needs ANY of the required roles
                unless (user_roles & role_requirements).any?
                  Otto.structured_log(:warn, "Role authorization failed",
                    Otto::LoggingHelpers.request_context(env).merge(
                      required_roles: role_requirements,
                      user_roles: user_roles,
                      user_id: result.user_id
                    )
                  )

                  return forbidden_response(env,
                    "Access denied: requires one of roles: #{role_requirements.join(', ')}")
                end

                Otto.structured_log(:debug, "Role authorization succeeded",
                  Otto::LoggingHelpers.request_context(env).merge(
                    required_roles: role_requirements,
                    user_roles: user_roles,
                    matched_roles: user_roles & role_requirements
                  )
                )
              end

              # Authentication and authorization succeeded - call wrapped handler
              return wrapped_handler.call(env, extra_params)
            end

            # Handle authentication failure - continue to next strategy
            if result.is_a?(AuthFailure)
              # Log authentication failure
              Otto.structured_log(:info, "Auth strategy result",
                Otto::LoggingHelpers.request_context(env).merge(
                  strategy: strategy_name,
                  success: false,
                  failure_reason: result.failure_reason,
                  duration: duration,
                  remaining_strategies: auth_requirements.size - auth_requirements.index(requirement) - 1
                )
              )

              failed_strategies << { strategy: strategy_name, reason: result.failure_reason }
              last_failure = result
            end
          end

          # All strategies failed - return 401
          total_duration = Otto::Utils.now_in_μs - total_start_time

          # Log comprehensive failure
          Otto.structured_log(:warn, "All auth strategies failed",
            Otto::LoggingHelpers.request_context(env).merge(
              strategies_attempted: failed_strategies.map { |f| f[:strategy] },
              total_duration: total_duration,
              failure_count: failed_strategies.size
            )
          )

          # Create anonymous result with comprehensive failure info
          # Note: env['REMOTE_ADDR'] is masked by IPPrivacyMiddleware by default
          metadata = {
            ip: env['REMOTE_ADDR'],
            auth_failure: "All authentication strategies failed",
            attempted_strategies: failed_strategies.map { |f| f[:strategy] },
            failure_reasons: failed_strategies.map { |f| f[:reason] }
          }
          metadata[:country] = env['otto.privacy.geo_country'] if env['otto.privacy.geo_country']

          # Use 'multi-strategy-failure' only for actual multi-strategy failures
          # For single-strategy failures, use the actual strategy name
          failure_strategy_name = if auth_requirements.size > 1
            'multi-strategy-failure'
          else
            failed_strategies.first[:strategy]
          end

          env['otto.strategy_result'] = StrategyResult.anonymous(
            metadata: metadata,
            strategy_name: failure_strategy_name
          )

          auth_failure_response(env, last_failure || AuthFailure.new(failure_reason: "Authentication required"))
        end

        private

        # Get strategy from auth_config hash with pattern matching
        #
        # Supports:
        # - Exact match: 'authenticated' → looks up auth_config[:auth_strategies]['authenticated']
        # - Prefix match: 'custom:value' → looks up 'custom' strategy
        #
        # Results are cached to avoid repeated lookups for the same requirement.
        #
        # NOTE: Role-based authorization should use route option `role=admin` instead of `auth=role:admin`
        # to properly separate authentication from authorization concerns.
        #
        # @param requirement [String] Auth requirement from route
        # @return [Array<AuthStrategy, String>, Array<nil, nil>] Tuple of [strategy, name] or [nil, nil]
        def get_strategy(requirement)
          return [nil, nil] unless auth_config && auth_config[:auth_strategies]

          # Check cache first (cache stores [strategy, name] tuples)
          return @strategy_cache[requirement] if @strategy_cache.key?(requirement)

          # Try exact match first - this has highest priority
          strategy = auth_config[:auth_strategies][requirement]
          if strategy
            result = [strategy, requirement]
            @strategy_cache[requirement] = result
            return result
          end

          # For colon-separated requirements like "custom:value", try prefix match
          if requirement.include?(':')
            prefix = requirement.split(':', 2).first

            # Check if we have a strategy registered for the prefix
            prefix_strategy = auth_config[:auth_strategies][prefix]
            if prefix_strategy
              result = [prefix_strategy, prefix]
              @strategy_cache[requirement] = result
              return result
            end
          end

          # Cache nil results too to avoid repeated failed lookups
          @strategy_cache[requirement] = [nil, nil]
          [nil, nil]
        end

        # Generate 401 response for authentication failure
        #
        # @param env [Hash] Rack environment
        # @param result [AuthFailure] Failure result from strategy
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
        # @param result [AuthFailure] Failure result
        # @return [Array] Rack response array
        def json_auth_error(result)
          body = {
            error: 'Authentication Required',
            message: result.failure_reason || 'Not authenticated',
            timestamp: Time.now.to_i
          }.to_json

          headers = {
            'content-type' => 'application/json',
            'content-length' => body.bytesize.to_s
          }

          # Add security headers if available
          merge_security_headers!(headers)

          [401, headers, [body]]
        end

        # Generate HTML 401 response or redirect
        #
        # @param result [AuthFailure] Failure result
        # @return [Array] Rack response array
        def html_auth_error(result)
          # For HTML requests, redirect to login
          login_path = auth_config[:login_path] || '/signin'

          headers = { 'location' => login_path }

          # Add security headers if available
          merge_security_headers!(headers)

          [302, headers, ["Redirecting to #{login_path}"]]
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
            headers = {
              'content-type' => 'application/json',
              'content-length' => body.bytesize.to_s
            }
            merge_security_headers!(headers)
            [401, headers, [body]]
          else
            headers = { 'content-type' => 'text/plain' }
            merge_security_headers!(headers)
            [401, headers, [message]]
          end
        end

        # Generate 403 Forbidden response for role authorization failure
        #
        # @param env [Hash] Rack environment
        # @param message [String] Error message
        # @return [Array] Rack response array
        def forbidden_response(env, message)
          accept_header = env['HTTP_ACCEPT'] || ''
          wants_json = accept_header.include?('application/json')

          if wants_json
            body = { error: 'Forbidden', message: message }.to_json
            headers = {
              'content-type' => 'application/json',
              'content-length' => body.bytesize.to_s
            }
            merge_security_headers!(headers)
            [403, headers, [body]]
          else
            headers = { 'content-type' => 'text/plain' }
            merge_security_headers!(headers)
            [403, headers, [message]]
          end
        end

        # Extract user roles from authentication result
        #
        # Supports multiple role sources in order of precedence:
        # 1. result.user_roles (Array)
        # 2. result.user[:roles] (Array)
        # 3. result.user['roles'] (Array)
        # 4. result.metadata[:user_roles] (Array)
        #
        # @param result [StrategyResult] Authentication result
        # @return [Array<String>] Array of role strings
        def extract_user_roles(result)
          # Try direct user_roles accessor (e.g., from RoleStrategy)
          return Array(result.user_roles) if result.respond_to?(:user_roles) && result.user_roles

          # Try user hash/object with roles
          if result.user
            roles = result.user[:roles] || result.user['roles']
            return Array(roles) if roles
          end

          # Try metadata
          if result.metadata && result.metadata[:user_roles]
            return Array(result.metadata[:user_roles])
          end

          # No roles found
          []
        end

        # Merge security headers into response headers
        #
        # @param headers [Hash] Response headers hash to merge into
        def merge_security_headers!(headers)
          return unless security_config

          headers.merge!(security_config.security_headers)
        end
      end
    end
  end
end
