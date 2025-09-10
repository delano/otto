# spec/test_security_defaults.rb
# Test script to verify Otto's safe security defaults
#
# This script verifies that dangerous security headers are not enabled
# by default and that they can be enabled explicitly when needed.

require_relative '../lib/otto'

def test_safe_defaults
  puts 'Testing Otto security defaults...'

  # Create Otto with default configuration
  otto = Otto.new
  config = otto.security_config
  default_headers = config.security_headers

  puts "\nDefault security headers:"
  default_headers.each { |k, v| puts "  #{k}: #{v}" }

  # Verify dangerous headers are NOT present by default
  dangerous_headers = %w[
    strict-transport-security
    content-security-policy
    x-frame-options
  ]

  dangerous_present = dangerous_headers.select { |h| default_headers.key?(h) }

  if dangerous_present.empty?
    puts "\n✓ PASS: No dangerous headers present by default"
  else
    puts "\n✗ FAIL: Dangerous headers found by default: #{dangerous_present.join(', ')}"
    return false
  end

  # Verify safe headers ARE present
  safe_headers = %w[
    x-content-type-options
    x-xss-protection
    referrer-policy
  ]

  safe_missing = safe_headers.reject { |h| default_headers.key?(h) }

  if safe_missing.empty?
    puts '✓ PASS: All safe headers present by default'
  else
    puts "✗ FAIL: Safe headers missing: #{safe_missing.join(', ')}"
    return false
  end

  # Test explicit enabling of dangerous headers
  puts "\nTesting explicit header enabling..."

  # Test HSTS
  otto.enable_hsts!
  if otto.security_config.security_headers['strict-transport-security']
    puts '✓ PASS: HSTS can be enabled explicitly'
  else
    puts '✗ FAIL: HSTS not enabled when requested'
    return false
  end

  # Test CSP
  otto.enable_csp!
  if otto.security_config.security_headers['content-security-policy']
    puts '✓ PASS: CSP can be enabled explicitly'
  else
    puts '✗ FAIL: CSP not enabled when requested'
    return false
  end

  # Test Frame Protection
  otto.enable_frame_protection!
  if otto.security_config.security_headers['x-frame-options']
    puts '✓ PASS: X-Frame-Options can be enabled explicitly'
  else
    puts '✗ FAIL: X-Frame-Options not enabled when requested'
    return false
  end

  # Test custom HSTS options
  otto2 = Otto.new
  otto2.enable_hsts!(max_age: 86_400, include_subdomains: false)
  hsts_value = otto2.security_config.security_headers['strict-transport-security']

  if hsts_value == 'max-age=86400'
    puts '✓ PASS: Custom HSTS options work correctly'
  else
    puts "✗ FAIL: Custom HSTS options not applied correctly (got: #{hsts_value})"
    return false
  end

  # Test custom CSP
  otto3 = Otto.new
  custom_policy = "default-src 'self'; script-src 'self' 'unsafe-inline'"
  otto3.enable_csp!(custom_policy)
  csp_value = otto3.security_config.security_headers['content-security-policy']

  if csp_value == custom_policy
    puts '✓ PASS: Custom CSP policy applied correctly'
  else
    puts '✗ FAIL: Custom CSP policy not applied correctly'
    return false
  end

  true
end

def test_backward_compatibility
  puts "\nTesting backward compatibility..."

  # Verify that creating Otto instances still works as before
  begin
    Otto.new
    Otto.new(nil, { csrf_protection: true })
    Otto.new(nil, { request_validation: true, trusted_proxies: ['10.0.0.1'] })

    puts '✓ PASS: All Otto initialization patterns work'
    true
  rescue StandardError => e
    puts "✗ FAIL: Backward compatibility broken: #{e.message}"
    false
  end
end

def test_configuration_isolation
  puts "\nTesting configuration isolation..."

  # Ensure different Otto instances have independent configurations
  otto1 = Otto.new
  otto2 = Otto.new

  otto1.enable_hsts!

  if otto1.security_config.security_headers['strict-transport-security'] &&
     !otto2.security_config.security_headers['strict-transport-security']
    puts '✓ PASS: Security configurations are properly isolated'
    true
  else
    puts '✗ FAIL: Security configurations are not isolated between instances'
    false
  end
end

# Run all tests
puts 'Otto Security Configuration Test Suite'
puts '=' * 50

all_passed = true
all_passed &= test_safe_defaults
all_passed &= test_backward_compatibility
all_passed &= test_configuration_isolation

puts "\n" + ('=' * 50)
if all_passed
  puts '🎉 ALL TESTS PASSED - Security defaults are safe!'
  puts "\nKey points:"
  puts '• Dangerous headers (HSTS, CSP, X-Frame-Options) are NOT enabled by default'
  puts '• Safe headers (X-Content-Type-Options, etc.) ARE enabled by default'
  puts '• Dangerous headers can be enabled explicitly when needed'
  puts '• Backward compatibility is maintained'
  exit 0
else
  puts '❌ SOME TESTS FAILED - Please review security configuration'
  exit 1
end
