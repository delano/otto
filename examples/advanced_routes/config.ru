# frozen_string_literal: true

require 'rack'
require_relative '../../lib/otto'
require_relative 'app'

# Simple Otto configuration demonstrating advanced routes syntax
# This example focuses on the routing syntax features without complex authentication
otto = Otto.new('routes')

# Enable basic security features to demonstrate CSRF functionality
otto.enable_csrf_protection!

# Set error handlers
otto.not_found = lambda do |env|
  RoutesApp.not_found
end

otto.server_error = lambda do |env, error|
  RoutesApp.server_error
end

run otto
