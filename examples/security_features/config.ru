# examples/security_features/config.ru

# OTTO SECURE EXAMPLE APP CONFIG - 2025-07-18
#
# Usage:
#
#     $ thin -e dev -R config.ru -p 10770 start
#

public_path = File.expand_path('../../public', __dir__)

require_relative '../../lib/otto'
require_relative 'app'

# Create Otto app with security features enabled
app = Otto.new('./routes', {
                 # Enable CSRF protection for POST, PUT, DELETE requests
                 csrf_protection: true,

  # Enable input validation and sanitization
  request_validation: true,

  # Configure trusted proxy servers (adjust for your infrastructure)
  trusted_proxies: [
    # The primary RFC 1918 private ranges
    '127.0.0.1',        # Local development
    '10.0.0.0/8',       # Private Class A
    '172.16.0.0/12',    # Private Class B
    '192.168.0.0/16',   # Private Class C

    # Other reserved ranges that I often forget about
    # '127.0.0.0/8',      # Loopback
    # '100.64.0.0/10',    # Carrier-grade NAT
    # '169.254.0.0/16',   # RFC 3927 - Automatic Private IP Addressing (APIPA)
    # '198.18.0.0/15',    # RFC 2544 - Benchmarking methodology
    # '203.0.113.0/24',   # RFC 5737 - Documentation examples
    # '224.0.0.0/4',      # Multicast
    # '240.0.0.0/4',      # RFC 1112 - Class E (experimental)
  ],

  # Custom security headers
  security_headers: {
    'content-security-policy' => "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'",
    'strict-transport-security' => 'max-age=31536000; includeSubDomains',
    'x-frame-options' => 'DENY',
  },
               })

# Optional: Configure additional security settings
app.security_config.max_request_size = 5 * 1024 * 1024 # 5MB limit
app.security_config.max_param_depth  = 10 # Limit parameter nesting
app.security_config.max_param_keys   = 50 # Limit parameters per request

# Optional: Add static file serving with security
app.option[:public] = public_path

# Development vs Production configuration
if ENV['RACK_ENV'] == 'production'
  # Production-specific settings
  app.security_config.require_secure_cookies = true

  # More restrictive CSP for production
  app.set_security_headers({
                             'content-security-policy' => "default-src 'self'; style-src 'self'; script-src 'self'; object-src 'none'",
    'strict-transport-security' => 'max-age=63072000; includeSubDomains; preload',
                           })
else
  # Development-specific settings
  puts '🔒 Security features enabled:'
  puts '   ✓ CSRF Protection'
  puts '   ✓ Input Validation'
  puts '   ✓ Request Size Limits'
  puts '   ✓ Security Headers'
  puts '   ✓ Trusted Proxy Support'
  puts ''
end

# Mount the application
map('/') do
  run app
end
