# lib/otto/helpers/response.rb

class Otto
  module ResponseHelpers
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
        samesite: :strict,
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
  end
end
