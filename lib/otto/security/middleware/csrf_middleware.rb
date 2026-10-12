# lib/otto/security/middleware/csrf_middleware.rb
#
# frozen_string_literal: true

require_relative '../config'
require_relative '../csrf_validation'

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
        include Otto::Security::CSRFValidation

        def initialize(app, config = nil)
          @app    = app
          @config = config || Otto::Security::Config.new
        end

        def call(env)
          return @app.call(env) unless @config.csrf_enabled?

          request  = Otto::Request.new(env)
          response = @app.call(env)
          return inject_csrf_token(request, with_copied_headers(response)) if html_response?(response)

          apply_binding_cookie(request, response)
        end

        private

        # +response+ with a copy of its headers, so #inject_csrf_token can add
        # the binding cookie, Cache-Control and Content-Length without
        # changing the app's headers, which the app may freeze or share
        # between responses.
        def with_copied_headers(response)
          response.dup.tap { |copy| copy[1] = response[1].dup }
        end

        # A safe request that resolved a CSRF binding (a JSON token endpoint)
        # but got a response that is not HTML still needs the binding cookie,
        # or a client that never loads an HTML page would get a new binding,
        # and a 403, on every request. The cookie follows the same rules as on
        # HTML responses (#ensure_session_cookie). Only a binding the client
        # does not already send is recorded in otto.csrf_binding (see
        # Otto::Security::Config#get_or_create_session_id).
        #
        # An unsafe request does not set it: one that passes the CSRF check
        # already carries its binding, and a cross-site one arrives without
        # the SameSite=Lax cookie, so a binding minted for its 403 (or for a
        # csrf=exempt route) would replace the victim's and void their open
        # forms. The app's headers are copied rather than changed, as the app
        # may freeze them or share them between responses.
        def apply_binding_cookie(request, response)
          binding_id = request.env['otto.csrf_binding']
          return response unless binding_id && safe_method?(request.request_method)
          return response unless response.is_a?(Array) && response.length >= 2

          new_cookie = binding_cookie(request, binding_id)
          return response unless new_cookie

          headers = response[1].dup
          append_binding_cookie(headers, new_cookie)
          response.dup.tap { |copy| copy[1] = headers }
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
            keep_out_of_shared_caches(headers)

            [status, headers, [body_content]]
          else
            response
          end
        end

        # Sets the binding cookie when its value differs from +session_id+.
        def ensure_session_cookie(request, headers, session_id)
          new_cookie = binding_cookie(request, session_id)
          append_binding_cookie(headers, new_cookie) if new_cookie
        end

        # The Set-Cookie value for the binding cookie, or nil when the request
        # already carries +session_id+ in it. On HTTPS the cookie is
        # __Host-otto_session (Secure, Path=/, no Domain); on HTTP it is
        # _otto_session. See Otto::Security::Config#csrf_binding_cookie_name.
        #
        # The value is URL-encoded because Rack URL-decodes cookie values when
        # it parses them (Rack::Utils.parse_cookies_header). A binding that is
        # not a hex token, such as an app-set session_id cookie on HTTP or a
        # value from the session, then reads back unchanged instead of being
        # cut at a ';' or decoded a second time.
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

        # Adds the binding cookie to +headers+ and keeps the response out of
        # shared caches (#keep_out_of_shared_caches).
        def append_binding_cookie(headers, cookie)
          append_set_cookie(headers, cookie)
          keep_out_of_shared_caches(headers)
        end

        # Marks a response that carries the binding cookie or an injected
        # token, both meant for one client, with Cache-Control: private.
        # RFC 9111, section 7.3: "the Set-Cookie response header field
        # [COOKIE] does not inhibit caching". Section 5.2.2.7: "The
        # unqualified private response directive indicates that a shared
        # cache MUST NOT store the response (i.e., the response is intended
        # for a single user)." The browser's own cache may still store it.
        #
        # A response on which the app set Cache-Control or Expires keeps the
        # app's choice, and gets nothing added.
        def keep_out_of_shared_caches(headers)
          return if headers.each_key.any? { |key| key.casecmp?('cache-control') || key.casecmp?('expires') }

          headers['cache-control'] = 'private'
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
