# frozen_string_literal: true

class Otto
  module Security
    module Authentication
      module RouteAuthWrapperComponents
        # Builds HTTP error responses for authentication/authorization failures
        #
        # Handles content negotiation (JSON vs HTML) and applies security headers.
        # Route's declared response_type takes precedence over Accept header.
        #
        # @example
        #   builder = ResponseBuilder.new(route_definition, auth_config, security_config)
        #   response = builder.unauthorized(env, "Invalid token")
        #   response = builder.forbidden(env, "Admin role required")
        #   response = builder.auth_failure(env, auth_failure_result)
        #
        class ResponseBuilder
          # @param route_definition [RouteDefinition] Route with response_type info
          # @param auth_config [Hash] Auth config with :login_path for HTML redirects
          # @param security_config [SecurityConfig, nil] Optional security config for headers
          def initialize(route_definition, auth_config, security_config = nil)
            @route_definition = route_definition
            @auth_config = auth_config
            @security_config = security_config
          end

          # Generate response for authentication failure
          #
          # @param env [Hash] Rack environment
          # @param result [AuthFailure] Failure result from strategy
          # @return [Array] Rack response array
          def auth_failure(env, result)
            wants_json?(env) ? json_auth_error(result) : html_auth_error(result)
          end

          # Generate 401 Unauthorized response
          #
          # @param env [Hash] Rack environment
          # @param message [String] Error message
          # @return [Array] Rack response array
          def unauthorized(env, message)
            if wants_json?(env)
              json_response(401, error: message)
            else
              text_response(401, message)
            end
          end

          # Generate 403 Forbidden response
          #
          # @param env [Hash] Rack environment
          # @param message [String] Error message
          # @return [Array] Rack response array
          def forbidden(env, message)
            if wants_json?(env)
              json_response(403, error: 'Forbidden', message: message)
            else
              text_response(403, message)
            end
          end

          private

          # Determine if response should be JSON based on route config and Accept header
          #
          # Route's declared response type takes precedence over Accept header.
          # This ensures API routes (response=json) always get JSON errors.
          #
          # @param env [Hash] Rack environment
          # @return [Boolean] true if response should be JSON
          def wants_json?(env)
            return true if @route_definition.response_type == 'json'

            accept_header = env['HTTP_ACCEPT'] || ''
            accept_header.include?('application/json')
          end

          # Generate JSON 401 response for auth failure
          def json_auth_error(result)
            json_response(401,
              error: 'Authentication Required',
              message: result.failure_reason || 'Not authenticated',
              timestamp: Time.now.to_i)
          end

          # Generate HTML 401 response (redirect to login)
          def html_auth_error(_result)
            login_path = @auth_config[:login_path] || '/signin'
            headers = { 'location' => login_path }
            merge_security_headers!(headers)
            [302, headers, ["Redirecting to #{login_path}"]]
          end

          # Build a JSON response with security headers
          def json_response(status, body_hash)
            body = body_hash.to_json
            headers = {
              'content-type' => 'application/json',
              'content-length' => body.bytesize.to_s,
            }
            merge_security_headers!(headers)
            [status, headers, [body]]
          end

          # Build a plain text response with security headers
          def text_response(status, message)
            headers = { 'content-type' => 'text/plain' }
            merge_security_headers!(headers)
            [status, headers, [message]]
          end

          # Merge security headers into response headers
          def merge_security_headers!(headers)
            return unless @security_config

            headers.merge!(@security_config.security_headers)
          end
        end
      end
    end
  end
end
