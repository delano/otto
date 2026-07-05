# frozen_string_literal: true

require 'rack'
require_relative '../../lib/otto'
require_relative 'app'

# Simple Otto configuration demonstrating advanced routes syntax.
#
# Lambda / inline route handlers (issue #41): procs are pre-registered by name
# and referenced from the routes file with the '&name' prefix. Lookup is O(1)
# by exact string — no eval, no dynamic code from the route file.
otto = Otto.new('routes', lambda_handlers: {
  # GET /ping &health_check response=json
  'health_check'    => ->(_req, _res, _extra_params) { { status: 'ok', at: Time.now.to_i } },

  # POST /hooks/receive &receive_webhook response=json csrf=exempt
  'receive_webhook' => ->(req, _res, _extra_params) { { received: true, method: req.request_method } },

  # GET /go/dashboard &to_dashboard response=redirect (returned String is the Location)
  'to_dashboard'    => ->(_req, _res, _extra_params) { '/dashboard' },
})

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
