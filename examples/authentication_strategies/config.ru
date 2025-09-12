# frozen_string_literal: true

require 'rack'
require_relative '../../lib/otto'
require_relative 'app/auth'
require_relative 'app/controllers/main_controller'
require_relative 'app/controllers/auth_controller'

# Configure Otto with advanced features
otto = Otto.new('routes')

# Enable security features to demonstrate advanced route parameters
otto.enable_csrf_protection!
otto.enable_request_validation!
otto.enable_authentication!

# Load and configure authentication strategies
AuthenticationSetup.configure(otto)

# Set error handlers
otto.not_found = ->(_env) { MainController.not_found }
otto.server_error = ->(_env, _error) { MainController.server_error }

run otto
