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
        #
        # @param env [Hash] Rack environment
        # @param extra_params [Hash] Additional parameters
        # @return [Array] Rack response array
        def call(env, extra_params = {})
          auth_requirement = route_definition.auth_requirement

          # Routes without auth requirement get anonymous StrategyResult
          unless auth_requirement
            # Note: env['REMOTE_ADDR'] is masked by IPPrivacyMiddleware by default
            metadata = { ip: env['REMOTE_ADDR'] }
            metadata[:country] = env['otto.privacy.geo_country'] if env['otto.privacy.geo_country']

            result = StrategyResult.anonymous(metadata: metadata)
            env['otto.strategy_result'] = result
            return wrapped_handler.call(env, extra_params)
          end

          # Routes WITH auth requirement: Execute authentication strategy
          strategy = get_strategy(auth_requirement)

          unless strategy
            Otto.logger.error "[RouteAuthWrapper] No strategy found for requirement: #{auth_requirement}"
            return unauthorized_response(env, "Authentication strategy not configured")
          end

          # Execute the strategy
          result = strategy.authenticate(env, auth_requirement)

          # Handle authentication failure
          if result.is_a?(AuthFailure)
            # Create anonymous result with failure info for logging/auditing
            # Note: env['REMOTE_ADDR'] is masked by IPPrivacyMiddleware by default
            metadata = {
              ip: env['REMOTE_ADDR'],
              auth_failure: result.failure_reason,
              attempted_strategy: auth_requirement
            }
            metadata[:country] = env['otto.privacy.geo_country'] if env['otto.privacy.geo_country']

            env['otto.strategy_result'] = StrategyResult.anonymous(metadata: metadata)
            return auth_failure_response(env, result)
          end

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

          # Authentication succeeded - call wrapped handler
          wrapped_handler.call(env, extra_params)
        end

        private

        # Get strategy from auth_config hash with sophisticated pattern matching
        #
        # Supports:
        # - Exact match: 'authenticated' → looks up auth_config[:auth_strategies]['authenticated']
        # - Prefix match: 'role:admin' → looks up 'role' strategy
        # - Fallback: 'role:*' → creates default RoleStrategy
        # - Fallback: 'permission:*' → creates default PermissionStrategy
        #
        # Results are cached to avoid repeated lookups for the same requirement.
        #
        # @param requirement [String] Auth requirement from route
        # @return [AuthStrategy, nil] Strategy instance or nil
        def get_strategy(requirement)
          return nil unless auth_config && auth_config[:auth_strategies]

          # Check cache first
          return @strategy_cache[requirement] if @strategy_cache.key?(requirement)

          # Try exact match first - this has highest priority
          strategy = auth_config[:auth_strategies][requirement]
          if strategy
            @strategy_cache[requirement] = strategy
            return strategy
          end

          # For colon-separated requirements like "role:admin", try prefix match
          if requirement.include?(':')
            prefix = requirement.split(':', 2).first

            # Check if we have a strategy registered for the prefix
            prefix_strategy = auth_config[:auth_strategies][prefix]
            if prefix_strategy
              @strategy_cache[requirement] = prefix_strategy
              return prefix_strategy
            end

            # Try fallback patterns for role: and permission: requirements
            if requirement.start_with?('role:')
              # Cache the fallback strategy under 'role:' key to create it only once
              strategy = @strategy_cache['role:'] ||= begin
                auth_config[:auth_strategies]['role'] || Strategies::RoleStrategy.new([])
              end
              @strategy_cache[requirement] = strategy
              return strategy
            elsif requirement.start_with?('permission:')
              # Cache the fallback strategy under 'permission:' key
              strategy = @strategy_cache['permission:'] ||= begin
                auth_config[:auth_strategies]['permission'] || Strategies::PermissionStrategy.new([])
              end
              @strategy_cache[requirement] = strategy
              return strategy
            end
          end

          # Cache nil results too to avoid repeated failed lookups
          @strategy_cache[requirement] = nil
          nil
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
