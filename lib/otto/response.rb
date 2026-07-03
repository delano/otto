# lib/otto/response.rb
#
# frozen_string_literal: true

require 'rack/response'

class Otto
  # Otto's enhanced Rack::Response class with built-in helpers
  #
  # This class extends Rack::Response with Otto's framework helpers for
  # HTTP response handling, cookie management, CSP headers, and security.
  # Projects can register additional helpers via Otto#register_response_helpers.
  #
  # @example Using Otto's response in route handlers
  #   def show(req, res)
  #     res.send_secure_cookie('session_id', token, 3600)
  #     res.apply_csp(req.csp_nonce)
  #     res.no_cache!
  #   end
  #
  # @see Otto#register_response_helpers
  class Response < Rack::Response
    # One-time-per-process guard for the #send_csp_headers deprecation warning.
    @send_csp_headers_deprecation_warned = false
    class << self
      attr_accessor :send_csp_headers_deprecation_warned # rubocop:disable ThreadSafety/ClassAndModuleAttributes
    end

    # Reference to the request object (needed by some response helpers)
    # @return [Otto::Request]
    attr_accessor :request

    def send_secure_cookie(name, value, ttl, opts = {})
      # Default security options
      defaults = {
           secure: true,
         httponly: true,
        same_site: :strict,
             path: '/',
      }

      # Merge with provided options
      cookie_opts = defaults.merge(opts)

      # Set expiration using max-age (preferred) and expires (fallback)
      if ttl&.positive?
        cookie_opts[:max_age] = ttl
        cookie_opts[:expires] = (Time.now.utc + ttl + 10)
      elsif ttl&.negative?
        # For deletion, set both to past date
        cookie_opts[:max_age] = 0
        cookie_opts[:expires] = Time.now.utc - 86_400
      end

      # Set the cookie value
      cookie_opts[:value] = value

      # Validate SameSite attribute
      valid_same_site         = [:strict, :lax, :none, 'Strict', 'Lax', 'None']
      cookie_opts[:same_site] = :strict unless valid_same_site.include?(cookie_opts[:same_site])

      # If SameSite=None, Secure must be true
      cookie_opts[:secure] = true if cookie_opts[:same_site].to_s.downcase == 'none'

      set_cookie name, cookie_opts
    end

    def send_session_cookie(name, value, opts = {})
      # Session cookies don't have expiration
      session_opts = opts.merge(
        secure: true,
        httponly: true,
        samesite: :strict
      )

      # Remove expiration-related options for session cookies
      session_opts.delete(:max_age)
      session_opts.delete(:expires)

      # Adjust secure flag for local development
      session_opts[:secure] = false if request.local?

      session_opts[:value] = value
      set_cookie name, session_opts
    end

    def cookie_security_headers
      # Add security headers that complement cookie security
      headers = {}

      # Prevent MIME type sniffing
      headers['x-content-type-options'] = 'nosniff'

      # Add referrer policy
      headers['referrer-policy'] = 'strict-origin-when-cross-origin'

      # Add frame options
      headers['x-frame-options'] = 'DENY'

      # Add XSS protection
      headers['x-xss-protection'] = '1; mode=block'

      headers
    end

    # Apply a nonce-based Content-Security-Policy to this response.
    #
    # This is THE emission helper: it routes through the single apply core
    # ({Otto::Security::CSP::Writer}), so all the invariants — enabled-only,
    # nonce-present, HTML-only, lowercase key, no duplicate — hold here exactly as
    # they do in the middleware, with no guard logic duplicated. The response's
    # Content-Type must already be set (it decides HTML-only); this helper does
    # NOT set it.
    #
    # `mode: :override` (the default) is the deliberate per-request call: it
    # REPLACES any existing CSP. Pass `mode: :backstop` to defer to an existing
    # policy instead.
    #
    # @param nonce [String] the per-request nonce (typically {Otto::Request#csp_nonce})
    # @param mode [Symbol] `:override` or `:backstop` (see {Otto::Security::CSP::Writer::MODES})
    # @param development_mode [Boolean] use development-friendly CSP directives
    # @param security_config [Otto::Security::Config, nil] config to use; resolved
    #   from the request env when omitted
    # @return [Otto::Security::CSP::Writer::Result] the outcome (applied?, policy,
    #   skip_reason) for uniform observability
    #
    # @example
    #   res['content-type'] = 'text/html; charset=utf-8'
    #   res.apply_csp(req.csp_nonce)
    def apply_csp(nonce, mode: :override, development_mode: false, security_config: nil)
      config = security_config || (request&.env && request.env['otto.security_config'])
      Otto::Security::CSP::Writer.apply(
        headers, nonce,
        config: config, mode: mode, development_mode: development_mode
      )
    end

    # @deprecated Use {#apply_csp} instead. Retained as a thin shim over the apply
    #   core so existing callers keep working while its historical quirks are
    #   fixed: a nil/empty nonce no longer emits a broken `script-src 'nonce-'`
    #   (it skips), a CSP is no longer emitted for non-HTML responses, and the
    #   override notice goes through {Otto.logger} instead of a bare `warn` to
    #   stderr. Unlike {#apply_csp}, it still sets the Content-Type for you and
    #   emits in `:override` mode.
    #
    # @param content_type [String] Content-Type to set if not already set
    # @param nonce [String] Nonce value to include in CSP directives
    # @param opts [Hash] Options
    # @option opts [Otto::Security::Config] :security_config Security config to use
    # @option opts [Boolean] :development_mode Use development-friendly CSP directives
    # @return [Otto::Security::CSP::Writer::Result]
    def send_csp_headers(content_type, nonce, opts = {})
      warn_send_csp_headers_deprecated

      # Historical behavior the shim keeps (apply_csp does not): default the
      # Content-Type so an HTML response is recognized as HTML.
      headers['content-type'] ||= content_type

      apply_csp(
        nonce,
        mode: :override,
        development_mode: opts[:development_mode] || false,
        security_config: opts[:security_config]
      )
    end

    # Set cache control headers to prevent caching
    #
    # This method sets comprehensive cache control headers to ensure that
    # the response is not cached by browsers, proxies, or CDNs. This is
    # particularly useful for sensitive pages or dynamic content that
    # should always be fresh.
    #
    # @return [void]
    #
    # @example
    #   res.no_cache!
    def no_cache!
      headers['cache-control'] = 'no-store, no-cache, must-revalidate, max-age=0'
      headers['expires']       = 'Mon, 7 Nov 2011 00:00:00 UTC'
      headers['pragma']        = 'no-cache'
    end

    # Build application path by joining path segments
    #
    # This method safely joins multiple path segments, handling
    # duplicate slashes and ensuring proper path formatting.
    # Includes the script name (mount point) as the first segment.
    #
    # @param paths [Array<String>] Path segments to join
    # @return [String] Properly formatted path
    #
    # @example
    #   app_path('api', 'v1', 'users')
    #   # => "/myapp/api/v1/users"
    #
    # @example
    #   app_path(['admin', 'settings'])
    #   # => "/myapp/admin/settings"
    def app_path(*paths)
      paths = paths.flatten.compact
      paths.unshift(request.env['SCRIPT_NAME']) if request&.env&.[]('SCRIPT_NAME')
      paths.join('/').gsub('//', '/')
    end

    private

    # Emit the #send_csp_headers deprecation notice at most once per process
    # (Response is per-request, so the guard lives on the class).
    #
    # The check-then-set on the class flag is deliberately unsynchronized: the
    # race is benign — worst case, two threads racing on the very first call each
    # log the notice once. The flag gates only a log line, never any behavior, so
    # a mutex would add contention on a hot path to save at most a couple of
    # duplicate deprecation lines at startup.
    def warn_send_csp_headers_deprecated
      return if self.class.send_csp_headers_deprecation_warned
      return unless defined?(Otto.logger) && Otto.logger

      self.class.send_csp_headers_deprecation_warned = true
      Otto.logger.warn(
        '[Otto::Response] #send_csp_headers is deprecated and will be removed in a ' \
        'future release; use #apply_csp(nonce, mode: :override) (set Content-Type first), ' \
        'or mount Otto::Security::CSP::EmitMiddleware via #enable_csp_emission!.'
      )
    end
  end
end
