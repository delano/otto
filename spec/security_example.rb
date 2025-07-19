#!/usr/bin/env ruby
# Security Configuration Example for Otto
#
# This example demonstrates how to configure Otto's security features safely.
# By default, Otto applies only basic security headers to avoid breaking
# downstream applications.

require_relative '../lib/otto'

# Basic Otto setup with minimal security (safe defaults)
# Only applies: X-Content-Type-Options, X-XSS-Protection, Referrer-Policy
basic_otto = Otto.new('routes')

# Enable CSRF protection for forms and AJAX requests
basic_otto.enable_csrf_protection!

# Enable input validation and sanitization
basic_otto.enable_request_validation!

# Production configuration with additional security measures
production_otto = Otto.new('routes.txt', {
  csrf_protection: true,
  request_validation: true,
  trusted_proxies: ['10.0.0.0/8', '172.16.0.0/12']
})

# Explicitly enable restrictive security headers for production
if ENV['RACK_ENV'] == 'production'
  # Enable HSTS - WARNING: Only do this when HTTPS is properly configured!
  # This will force all future requests to use HTTPS
  production_otto.enable_hsts!(
    max_age: 31536000,    # 1 year
    include_subdomains: true
  )

  # Enable Content Security Policy to prevent XSS
  # Start with a restrictive policy and adjust as needed
  production_otto.enable_csp!(
    "default-src 'self'; " \
    "script-src 'self' 'unsafe-inline'; " \
    "style-src 'self' 'unsafe-inline'; " \
    "img-src 'self' data: https:; " \
    "font-src 'self' https:; " \
    "connect-src 'self'"
  )

  # Prevent clickjacking attacks
  production_otto.enable_frame_protection!('SAMEORIGIN')

  # Add additional security headers
  production_otto.set_security_headers({
    'permissions-policy' => 'geolocation=(), microphone=(), camera=()',
    'cross-origin-opener-policy' => 'same-origin-allow-popups',
    'cross-origin-embedder-policy' => 'unsafe-none'
  })
end

# Development configuration - more permissive for easier debugging
development_otto = Otto.new('routes.txt', {
  csrf_protection: true,
  request_validation: true
})

# For development, you might want a more permissive CSP
if ENV['RACK_ENV'] == 'development'
  development_otto.enable_csp!(
    "default-src 'self'; " \
    "script-src 'self' 'unsafe-inline' 'unsafe-eval'; " \
    "style-src 'self' 'unsafe-inline'; " \
    "img-src 'self' data: blob: https: http:; " \
    "font-src 'self' data: https: http:; " \
    "connect-src 'self' ws: wss:"
  )

  # Allow framing for development tools
  development_otto.enable_frame_protection!('SAMEORIGIN')
end

# Example: API-only service with minimal HTML output
api_otto = Otto.new('api_routes.txt', {
  csrf_protection: false,    # APIs typically use tokens instead
  request_validation: true,
  trusted_proxies: ['10.0.0.0/8']
})

# API services might want different security headers
api_otto.set_security_headers({
  'x-frame-options' => 'DENY',
  'access-control-allow-origin' => 'https://yourdomain.com',
  'access-control-allow-methods' => 'GET, POST, PUT, DELETE',
  'access-control-allow-headers' => 'Content-Type, Authorization'
})

# Example: High-security application
high_security_otto = Otto.new('secure_routes.txt', {
  csrf_protection: true,
  request_validation: true,
  trusted_proxies: ['10.0.0.0/8']
})

# Maximum security configuration
if ENV['HIGH_SECURITY'] == 'true'
  # Very strict HSTS
  high_security_otto.enable_hsts!(
    max_age: 63072000,    # 2 years
    include_subdomains: true
  )

  # Strict CSP with nonce support
  high_security_otto.enable_csp!(
    "default-src 'none'; " \
    "script-src 'self'; " \
    "style-src 'self'; " \
    "img-src 'self'; " \
    "font-src 'self'; " \
    "connect-src 'self'; " \
    "base-uri 'self'; " \
    "form-action 'self'"
  )

  # Completely deny framing
  high_security_otto.enable_frame_protection!('DENY')

  # Additional security headers
  high_security_otto.set_security_headers({
    'permissions-policy' => 'geolocation=(), microphone=(), camera=(), payment=(), usb=()',
    'cross-origin-opener-policy' => 'same-origin',
    'cross-origin-embedder-policy' => 'require-corp',
    'cross-origin-resource-policy' => 'same-origin',
    'expect-ct' => 'max-age=86400, enforce'
  })

  # Stricter validation limits
  high_security_otto.security_config.max_request_size = 1024 * 1024  # 1MB
  high_security_otto.security_config.max_param_depth = 16
  high_security_otto.security_config.max_param_keys = 32
end

puts "Security examples configured successfully!"
puts "Default headers applied: #{basic_otto.security_config.security_headers.keys.join(', ')}"
puts "Remember: HSTS, CSP, and X-Frame-Options are NOT enabled by default"
puts "Enable them explicitly when your application is ready for the restrictions"
