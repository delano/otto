# examples/advanced_routes/config.rb

require 'rack'
require_relative '../../lib/otto'
require_relative 'app'

# Simple Otto configuration demonstrating advanced routes syntax
otto = Otto.new('routes')

# Enable basic security features to demonstrate CSRF functionality
otto.enable_csrf_protection!

# Set error handlers
otto.not_found = lambda do |_env|
  RoutesApp.not_found
end

otto.server_error = lambda do |_env, _error|
  RoutesApp.server_error
end

# Return the configured app. This allows runner scripts to use the same instance.
otto
