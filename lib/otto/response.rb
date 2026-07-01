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
  #     res.send_csp_headers('text/html', nonce)
  #     res.no_cache!
  #   end
  #
  # @see Otto#register_response_helpers
  class Response < Rack::Response
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

    # Set Content Security Policy (CSP) headers with nonce support
    #
    # This method generates and sets CSP headers with the provided nonce value,
    # following the same usage pattern as send_cookie methods. The CSP policy
    # is generated dynamically based on the security configuration and environment.
    #
    # The apply itself is delegated to the shared, casing-safe core
    # {Otto::Security::Config#write_nonce_csp} with `clobber: true`: an existing
    # CSP header is deliberately overridden (with a warning), while a blank
    # nonce or a non-HTML content type skips emission rather than producing a
    # broken or pointless policy.
    #
    # @param content_type [String] Content-Type header value to set
    # @param nonce [String] Nonce value to include in CSP directives
    # @param opts [Hash] Options for CSP generation
    # @option opts [Otto::Security::Config] :security_config Security config to use
    # @option opts [Boolean] :development_mode Use development-friendly CSP directives
    # @option opts [Boolean] :debug Enable debug logging for this request
    # @return [void]
    #
    # @example Basic usage
    #   nonce = SecureRandom.base64(16)
    #   res.send_csp_headers('text/html; charset=utf-8', nonce)
    #
    # @example With options
    #   res.send_csp_headers('text/html; charset=utf-8', nonce, {
    #     development_mode: Rails.env.development?,
    #     debug: true
    #   })
    def send_csp_headers(content_type, nonce, opts = {})
      # Set content type if not already set
      headers['content-type'] ||= content_type

      # Warn if CSP header already exists but don't skip
      warn 'CSP header already set, overriding with nonce-based policy' if headers['content-security-policy']

      # Get security configuration
      security_config = opts[:security_config] ||
                        (request&.env && request.env['otto.security_config']) ||
                        nil

      # Skip if CSP nonce support is not enabled
      return unless security_config&.csp_nonce_enabled?

      # Apply through the shared, casing-safe core. #headers is a Rack::Headers
      # (Rack 3.1+), so it is mutated in place; clobber: true preserves this
      # helper's override-an-existing-CSP behavior. The core also skips blank
      # nonces and non-HTML content types.
      before = headers['content-security-policy']
      security_config.write_nonce_csp(
        headers, nonce,
        development_mode: opts[:development_mode] || false,
        clobber: true
      )
      log_csp_debug(security_config, opts[:debug], before)
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

    # Log the CSP policy written by #send_csp_headers when debug logging is
    # enabled. `before` is the header value prior to the apply; the shared core
    # may have skipped (blank nonce, non-HTML), in which case nothing is logged.
    def log_csp_debug(security_config, debug_opt, before)
      csp_policy = headers['content-security-policy']
      return if csp_policy.nil? || csp_policy.equal?(before)
      return unless debug_opt || security_config.debug_csp?

      Otto.logger.debug "[CSP] #{csp_policy}" if defined?(Otto.logger)
    end
  end
end
