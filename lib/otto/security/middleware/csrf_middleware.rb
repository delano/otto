# lib/otto/security/middleware/csrf_middleware.rb
#
# frozen_string_literal: true

require_relative '../config'

class Otto
  module Security
    module Middleware
      # Global middleware that injects CSRF tokens into HTML responses.
      #
      # Token *enforcement* deliberately does NOT live here. This middleware
      # runs ahead of route matching, so it cannot see per-route options like
      # +csrf=exempt+ (issue #186); enforcing globally would block routes an
      # operator explicitly exempted. Enforcement is applied after matching by
      # +Otto::Security::CSRFEnforcementWrapper+ at the handler layer, where the
      # route definition is available. This middleware keeps only the
      # response-shaping half — injecting a fresh token into HTML responses so
      # forms and meta tags can carry it — which is method/content-type based
      # and correctly stays global.
      class CSRFMiddleware
        def initialize(app, config = nil)
          @app    = app
          @config = config || Otto::Security::Config.new
        end

        def call(env)
          return @app.call(env) unless @config.csrf_enabled?

          request  = Otto::Request.new(env)
          response = @app.call(env)
          response = inject_csrf_token(request, response) if html_response?(response)
          response
        end

        private

        def inject_csrf_token(request, response)
          return response unless response.is_a?(Array) && response.length >= 3

          status, headers, body = response
          content_type          = headers.find { |k, _v| k.downcase == 'content-type' }&.last

          return response unless content_type&.include?('text/html')

          # Get or create session ID
          session_id = @config.get_or_create_session_id(request)

          # Ensure session ID is saved to cookie if it was newly created
          ensure_session_cookie(request, headers, session_id)

          # Generate new CSRF token
          csrf_token = @config.generate_csrf_token(session_id)

          # Inject meta tag into HTML head
          body_content = body.respond_to?(:join) ? body.join : body.to_s

          head_open_tag = /<head(?:\s[^>]*)?>/i
          if body_content.match?(head_open_tag)
            meta_tag     = %(<meta name="csrf-token" content="#{csrf_token}">)
            body_content = body_content.sub(head_open_tag) { |tag| "#{tag}\n#{meta_tag}" }

            # Update content length if present
            content_length_key          = headers.keys.find { |k| k.downcase == 'content-length' }
            headers[content_length_key] = body_content.bytesize.to_s if content_length_key

            [status, headers, [body_content]]
          else
            response
          end
        end

        def ensure_session_cookie(request, headers, session_id)
          # Check if session ID already exists in cookies
          existing_cookie = request.cookies['_otto_session']
          return if existing_cookie == session_id

          # Set the session cookie
          cookie_value  = "#{session_id}; Path=/; HttpOnly; SameSite=Lax"
          cookie_value += '; Secure' if request.scheme == 'https'

          # Handle existing Set-Cookie headers
          existing_cookies = headers['set-cookie'] || headers['Set-Cookie']
          if existing_cookies
            # Append to existing cookies (handle both string and array formats)
            if existing_cookies.is_a?(Array)
              existing_cookies << "_otto_session=#{cookie_value}"
            else
              headers['set-cookie'] = [existing_cookies, "_otto_session=#{cookie_value}"]
            end
          else
            headers['set-cookie'] = "_otto_session=#{cookie_value}"
          end
        end

        def html_response?(response)
          return false unless response.is_a?(Array) && response.length >= 2

          headers      = response[1]
          content_type = headers.find { |k, _v| k.downcase == 'content-type' }&.last
          content_type&.include?('text/html')
        end
      end
    end
  end
end
