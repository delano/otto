# lib/otto/helpers/response.rb

class Otto
  module ResponseHelpers
    attr_accessor :request

    def send_secure_cookie(name, value, ttl, opts = {})
      send_cookie name, value, ttl, opts.merge(secure: true)
    end

    def send_cookie(name, value, ttl, opts = {})
      # Default security options
      defaults = {
        secure: true,
        httponly: true,
        samesite: :lax,
        path: '/'
      }
      
      # Merge with provided options
      cookie_opts = defaults.merge(opts)
      
      # Adjust secure flag for local development
      if request.local?
        cookie_opts[:secure] = false
      end
      
      # Set expiration using max-age (preferred) and expires (fallback)
      if ttl && ttl > 0
        cookie_opts[:max_age] = ttl
        cookie_opts[:expires] = (Time.now.utc + ttl + 10)
      elsif ttl && ttl < 0
        # For deletion, set both to past date
        cookie_opts[:max_age] = 0
        cookie_opts[:expires] = Time.now.utc - 86400
      end
      
      # Set the cookie value
      cookie_opts[:value] = value
      
      # Validate SameSite attribute
      valid_samesite = [:strict, :lax, :none, 'Strict', 'Lax', 'None']
      unless valid_samesite.include?(cookie_opts[:samesite])
        cookie_opts[:samesite] = :lax
      end
      
      # If SameSite=None, Secure must be true
      if cookie_opts[:samesite].to_s.downcase == 'none'
        cookie_opts[:secure] = true
      end
      
      set_cookie name, cookie_opts
    end

    def delete_cookie(name, opts = {})
      # Ensure we use the same path and domain when deleting
      delete_opts = {
        path: opts[:path] || '/',
        domain: opts[:domain],
        secure: opts[:secure],
        httponly: opts[:httponly],
        samesite: opts[:samesite]
      }.compact
      
      send_cookie name, '', -1, delete_opts
    end
    
    def send_session_cookie(name, value, opts = {})
      # Session cookies don't have expiration
      session_opts = opts.merge(
        secure: true,
        httponly: true,
        samesite: :lax
      )
      
      # Remove expiration-related options for session cookies
      session_opts.delete(:max_age)
      session_opts.delete(:expires)
      
      # Adjust secure flag for local development
      if request.local?
        session_opts[:secure] = false
      end
      
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
