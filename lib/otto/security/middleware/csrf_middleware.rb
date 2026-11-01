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

          request       = Otto::Request.new(env)
          # Read before @app.call: a session store inside this middleware
          # replaces rack.session there (see #record_store_minted_binding).
          outer_session = env['rack.session']
          response      = @app.call(env)
          response      = inject_csrf_token(request, response, outer_session) if html_response?(response)

          apply_binding_cookie(request, response)
        end

        private

        # Sets the binding cookie on any response, HTML or not, to a safe
        # request that resolved a binding the client does not already send:
        # one minted, or read from csrf_session_key, which
        # Otto::Security::Config#get_or_create_session_id records in
        # otto.csrf_binding (as does #record_store_minted_binding for a store
        # that runs inside this middleware). A JSON client that never loads an
        # HTML page needs it too, or it would get a new binding, and a 403, on
        # every request.
        #
        # A session id the request already had and a binding read from a
        # cookie are not recorded, so they are never copied: the client sends
        # them again, and a copy would sit in a second cookie whose lifetime
        # and attributes the application does not configure. A session id
        # read from a cookie someone planted would outlive the session cookie
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

        def inject_csrf_token(request, response, outer_session)
          return response unless response.is_a?(Array) && response.length >= 3

          status, headers, body = response
          return response unless html_content_type?(headers)

          session_id = token_binding(request, outer_session)
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
        def token_binding(request, outer_session)
          return @config.existing_session_id(request) unless safe_method?(request.request_method)

          existing_id = @config.existing_session_id(request)
          binding_id  = @config.get_or_create_session_id(request)
          record_store_minted_binding(request, binding_id, outer_session) unless existing_id
          binding_id
        end

        # Records a binding minted here in otto.csrf_binding when it is the id
        # a session store created for Otto's write and that store will not
        # send it. get_or_create_session_id does not record a store's id,
        # because the store sends it in its own cookie when it commits. That
        # holds for +outer_session+, set up by a store that wraps this
        # middleware and commits after it returns. A store added inside this
        # middleware (with otto.use before CSRF protection is enabled) has
        # committed before the token is injected, so it never sends the id it
        # creates here, and only the binding cookie can carry it.
        # The id is new, so this copies nothing a client could have planted.
        def record_store_minted_binding(request, binding_id, outer_session)
          return if session_id_of?(outer_session, binding_id)

          request.env['otto.csrf_binding'] = binding_id
        end

        # Whether +binding_id+ is the id of +session+.
        def session_id_of?(session, binding_id)
          session.respond_to?(:id) && session.id.to_s == binding_id
        rescue StandardError
          false
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

          html_content_type?(response[1])
        end

        # Whether +headers+ declare a text/html Content-Type, under any case
        # of the key.
        def html_content_type?(headers)
          content_type = headers.find { |k, _v| k.downcase == 'content-type' }&.last
          content_type&.include?('text/html')
        end
      end
    end
  end
end
