# lib/otto/security/middleware/csrf_middleware.rb
#
# frozen_string_literal: true

require_relative '../config'
require_relative '../csrf_validation'

class Otto
  module Security
    module Middleware
      # Global middleware that injects CSRF tokens into HTML responses and
      # sets the CSRF binding cookie on responses to safe requests.
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
        include Otto::Security::CSRFValidation

        def initialize(app, config = nil)
          @app    = app
          @config = config || Otto::Security::Config.new
        end

        def call(env)
          return @app.call(env) unless @config.csrf_enabled?

          request  = Otto::Request.new(env)
          response = @app.call(env)
          response = inject_csrf_token(request, response) if html_response?(response)

          apply_binding_cookie(request, response)
        end

        private

        # Sets the binding cookie on any response, HTML or not, to a safe
        # request that resolved a binding the client does not already send:
        # one minted, or read from csrf_session_key, which
        # Otto::Security::Config#get_or_create_session_id records in
        # otto.csrf_binding. A JSON client that never loads an HTML page
        # needs it too, or it would get a new binding, and a 403, on every
        # request.
        #
        # The session store's own id and a binding read from a cookie are
        # not recorded, so they are never copied: the client sends them
        # again, and a copy would sit in a second cookie whose lifetime and
        # attributes the application does not configure. A session id read
        # from a cookie someone planted would outlive the session cookie
        # there.
        #
        # An unsafe request does not set it: one that passes the CSRF check
        # already carries its binding, and a cross-site one arrives without
        # the SameSite=Lax cookie, so a binding set on its response would
        # replace the victim's and void their open forms. The app's headers
        # are copied rather than changed, as the app may freeze them or share
        # them between responses.
        def apply_binding_cookie(request, response)
          binding_id = request.env['otto.csrf_binding']
          return response unless binding_id && safe_method?(request.request_method)
          return response unless response.is_a?(Array) && response.length >= 2

          new_cookie = binding_cookie(request, binding_id)
          return response unless new_cookie

          headers = response[1].dup
          append_set_cookie(headers, new_cookie)
          response.dup.tap { |copy| copy[1] = headers }
        end

        def inject_csrf_token(request, response)
          return response unless response.is_a?(Array) && response.length >= 3

          status, headers, body = response
          content_type          = headers.find { |k, _v| k.downcase == 'content-type' }&.last

          return response unless content_type&.include?('text/html')

          session_id = token_binding(request)
          return response unless session_id

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

        # The binding the injected token is bound to. A safe request gets one
        # minted when it has none. An unsafe request uses only the binding it
        # already has: a cross-site POST to a csrf=exempt route arrives
        # without the SameSite=Lax binding cookie, and a binding minted for
        # it would replace the victim's (or, behind a session store, commit a
        # new session over theirs). Without a binding the page gets no token.
        def token_binding(request)
          return @config.get_or_create_session_id(request) if safe_method?(request.request_method)

          @config.existing_session_id(request)
        end

        # The Set-Cookie value for the binding cookie, or nil when the request
        # already carries +session_id+ in it. On HTTPS the cookie is
        # __Host-otto_session (Secure, Path=/, no Domain); on HTTP it is
        # _otto_session. See Otto::Security::Config#csrf_binding_cookie_name.
        #
        # The value is URL-encoded because Rack URL-decodes cookie values when
        # it parses them (Rack::Utils.parse_cookies_header). A binding that is
        # not a hex token, such as a value an app stored under
        # csrf_session_key, then reads back unchanged instead of being cut at
        # a ';' or decoded a second time.
        def binding_cookie(request, session_id)
          cookie_name = @config.csrf_binding_cookie_name(request)
          return if request.cookies[cookie_name] == session_id

          cookie_value  = "#{Rack::Utils.escape(session_id.to_s)}; Path=/; HttpOnly; SameSite=Lax"
          cookie_value += '; Secure' if request.scheme == 'https'
          "#{cookie_name}=#{cookie_value}"
        end

        # Adds +cookie+ to the Set-Cookie header. An existing value, String or
        # Array, is replaced by a new Array rather than appended to in place,
        # since the app may freeze it or share it between responses. A plain
        # Hash that spells the header Set-Cookie keeps that key.
        def append_set_cookie(headers, cookie)
          key          = !headers.key?('set-cookie') && headers.key?('Set-Cookie') ? 'Set-Cookie' : 'set-cookie'
          existing     = headers[key]
          headers[key] = existing ? [*existing, cookie] : cookie
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
