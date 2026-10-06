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
          return inject_csrf_token(request, response) if html_response?(response)

          apply_binding_cookie(request, response)
        end

        private

        # A request that resolved a CSRF binding (a JSON token endpoint, a
        # CSRF-checked API call) but got a response that is not HTML still
        # needs the binding cookie, or a client that never loads an HTML page
        # would get a new binding, and a 403, on every request. The cookie
        # follows the same rules as on HTML responses (#ensure_session_cookie).
        # A binding that is the session store's own id is not recorded in
        # otto.csrf_binding, so it is not copied into the cookie here.
        def apply_binding_cookie(request, response)
          binding_id = request.env['otto.csrf_binding']
          return response unless binding_id && response.is_a?(Array) && response.length >= 2

          ensure_session_cookie(request, response[1], binding_id)
          response
        end

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

        # Sets the binding cookie when its value differs from +session_id+.
        # On HTTPS the cookie is __Host-otto_session (Secure, Path=/, no
        # Domain); on HTTP it is _otto_session. See
        # Otto::Security::Config#csrf_binding_cookie_name.
        #
        # The value is URL-encoded because Rack URL-decodes cookie values when
        # it parses them (Rack::Utils.parse_cookies_header). A binding that is
        # not a hex token, such as an app-set session_id cookie on HTTP or a
        # value from the session, then reads back unchanged instead of being
        # cut at a ';' or decoded a second time.
        def ensure_session_cookie(request, headers, session_id)
          cookie_name = @config.csrf_binding_cookie_name(request)
          return if request.cookies[cookie_name] == session_id

          cookie_value  = "#{Rack::Utils.escape(session_id.to_s)}; Path=/; HttpOnly; SameSite=Lax"
          cookie_value += '; Secure' if request.scheme == 'https'
          new_cookie    = "#{cookie_name}=#{cookie_value}"

          # Handle existing Set-Cookie headers
          existing_cookies = headers['set-cookie'] || headers['Set-Cookie']
          if existing_cookies
            # Append to existing cookies (handle both string and array formats)
            if existing_cookies.is_a?(Array)
              existing_cookies << new_cookie
            else
              headers['set-cookie'] = [existing_cookies, new_cookie]
            end
          else
            headers['set-cookie'] = new_cookie
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
