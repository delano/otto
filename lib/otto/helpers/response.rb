# frozen_string_literal: true

# lib/otto/helpers/response.rb

require_relative 'base'

class Otto
  # Response helper methods providing HTTP response handling utilities
  module ResponseHelpers
    include Otto::BaseHelpers

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

      # Generate CSP policy with nonce
      development_mode = opts[:development_mode] || false
      csp_policy       = security_config.generate_nonce_csp(nonce, development_mode: development_mode)

      # Debug logging if enabled
      debug_enabled = opts[:debug] || security_config.debug_csp?
      if debug_enabled && defined?(Otto.logger)
        Otto.logger.debug "[CSP] #{csp_policy}"
      end

      # Set the CSP header
      headers['content-security-policy'] = csp_policy
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
  end
end
