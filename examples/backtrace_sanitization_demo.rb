#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo script showing Otto's automatic backtrace sanitization in structured_log
#
# This demonstrates that Otto now automatically sanitizes backtraces when they
# appear in structured log data, eliminating the need for monkey patches.

require_relative '../lib/otto'
require 'logger'

# Set up Otto with a logger to see the output
Otto.logger = Logger.new($stdout)
Otto.logger.level = Logger::DEBUG
Otto.debug = true

puts "=== Otto Backtrace Sanitization Demo ==="
puts

# Example 1: Raw backtrace with sensitive paths
puts "1. Raw backtrace with sensitive system paths:"
raw_backtrace = [
  '/Users/admin/secret-project/app/controllers/users_controller.rb:42:in `create\'',
  '/home/deploy/.rbenv/versions/3.2.0/lib/ruby/gems/3.2.0/gems/rack-3.1.8/lib/rack/builder.rb:310:in `call\'',
  '/usr/local/ruby/3.2.0/lib/ruby/3.2.0/logger.rb:310:in `add\'',
  '/opt/bundler/gems/custom-gem-abc123def456/lib/custom.rb:50:in `process\'',
  '/some/unknown/external/path/mystery.rb:100:in `mystery_method\''
]

Otto.structured_log(:error, 'Exception backtrace', {
  error_id: 'demo123',
  error: 'User creation failed',
  backtrace: raw_backtrace
})

puts

# Example 2: Non-backtrace data remains unchanged
puts "2. Non-backtrace arrays are not affected:"
Otto.structured_log(:info, 'Request processed', {
  method: 'POST',
  path: '/users',
  tags: ['important', 'user-creation', 'api'],
  middleware_stack: ['CSRF', 'Auth', 'RateLimit']
})

puts

# Example 3: Mixed data with backtrace
puts "3. Mixed data with backtrace gets selectively sanitized:"
Otto.structured_log(:warn, 'Validation warning with context', {
  user_id: 'user_456',
  validation_errors: ['email_invalid', 'password_too_short'],
  backtrace: [
    '/Users/developer/my-app/lib/validators/email.rb:25:in `validate_format\'',
    '/home/app/.bundle/gems/activemodel-7.0.0/lib/active_model/validator.rb:155:in `validate\''
  ],
  request_id: 'req_789'
})

puts

# Example 4: Empty or nil backtrace handling
puts "4. Handles edge cases gracefully:"
Otto.structured_log(:debug, 'Debug with empty backtrace', {
  event: 'method_entry',
  backtrace: [],
  timestamp: Time.now.to_f
})

Otto.structured_log(:info, 'Info with nil backtrace', {
  event: 'cache_hit',
  backtrace: nil,
  cache_key: 'user:123'
})

puts
puts "=== Demo Complete ==="
puts
puts "Notice how:"
puts "• Project paths become relative: 'app/controllers/users_controller.rb:42'"
puts "• Gem paths get [GEM] prefix with versions removed: '[GEM] rack/lib/rack/builder.rb:310'"
puts "• Ruby stdlib gets [RUBY] prefix: '[RUBY] logger.rb:310'"
puts "• Unknown paths get [EXTERNAL] prefix: '[EXTERNAL] mystery.rb:100'"
puts "• Non-backtrace arrays remain unchanged"
puts "• This happens automatically in Otto.structured_log - no monkey patching needed!"
