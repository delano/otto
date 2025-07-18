# example/secure_config.ru

require_relative '../lib/otto'
require_relative 'secure_app'

# Create Otto app with security features enabled
app = Otto.new("./secure_routes", {
  # Enable CSRF protection for POST, PUT, DELETE requests
  csrf_protection: true,

  # Enable input validation and sanitization
  request_validation: true,

  # Configure trusted proxy servers (adjust for your infrastructure)
  trusted_proxies: [
    '127.0.0.1',        # Local development
    '10.0.0.0/8',       # Private networks
    '172.16.0.0/12',    # Private networks  
    '192.168.0.0/16'    # Private networks
  ],

  # Custom security headers
  security_headers: {
    'content-security-policy' => "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'",
    'strict-transport-security' => 'max-age=31536000; includeSubDomains',
    'x-frame-options' => 'DENY'
  }
})

# Optional: Configure additional security settings
app.security_config.max_request_size = 5 * 1024 * 1024  # 5MB limit
app.security_config.max_param_depth = 10                # Limit parameter nesting
app.security_config.max_param_keys = 50                 # Limit parameters per request

# Optional: Add static file serving with security
# Uncomment and adjust path as needed
# app.option[:public] = File.expand_path('./public', __dir__)

# Development vs Production configuration
if ENV['RACK_ENV'] == 'production'
  # Production-specific settings
  app.security_config.require_secure_cookies = true

  # More restrictive CSP for production
  app.set_security_headers({
    'content-security-policy' => "default-src 'self'; style-src 'self'; script-src 'self'; object-src 'none'",
    'strict-transport-security' => 'max-age=63072000; includeSubDomains; preload'
  })
else
  # Development-specific settings
  puts "🔒 Security features enabled:"
  puts "   ✓ CSRF Protection"
  puts "   ✓ Input Validation"
  puts "   ✓ Request Size Limits"
  puts "   ✓ Security Headers"
  puts "   ✓ Trusted Proxy Support"
  puts ""
end

# Mount the application
map('/') {
  run app
}
