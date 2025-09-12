# frozen_string_literal: true

require 'rack'
require_relative '../../lib/otto'
require_relative 'app'

# Configure Otto with advanced features
otto = Otto.new('routes')

# Enable security features to demonstrate advanced route parameters
otto.enable_csrf_protection!
otto.enable_request_validation!
otto.enable_authentication!

# Configure authentication strategies for the demo
otto.add_auth_strategy('authenticated', lambda do |req|
  # Simple auth strategy that checks for a token parameter or header
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  if token == 'demo_token'
    OpenStruct.new(
      session: { session_id: 'demo_session_123', user_id: 1 },
      user: { name: 'Demo User', role: 'user', permissions: %w[read write] }
    )
  end
end)

otto.add_auth_strategy('role:admin', lambda do |req|
  # Role-based auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  if token == 'admin_token'
    OpenStruct.new(
      session: { session_id: 'admin_session_456', user_id: 2 },
      user: { name: 'Admin User', role: 'admin', permissions: %w[read write admin delete] }
    )
  end
end)

otto.add_auth_strategy('role:moderator', lambda do |req|
  # Moderator role auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  if token == 'mod_token'
    OpenStruct.new(
      session: { session_id: 'mod_session_789', user_id: 3 },
      user: { name: 'Moderator User', role: 'moderator', permissions: %w[read write moderate] }
    )
  end
end)

otto.add_auth_strategy('permission:write', lambda do |req|
  # Permission-based auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  case token
  when 'demo_token'
    OpenStruct.new(
      session: { session_id: 'demo_session_123', user_id: 1 },
      user: { name: 'Demo User', role: 'user', permissions: %w[read write] }
    )
  when 'admin_token'
    OpenStruct.new(
      session: { session_id: 'admin_session_456', user_id: 2 },
      user: { name: 'Admin User', role: 'admin', permissions: %w[read write admin delete] }
    )
  end
end)

otto.add_auth_strategy('permission:publish', lambda do |req|
  # Publish permission auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  if token == 'admin_token'
    OpenStruct.new(
      session: { session_id: 'admin_session_456', user_id: 2 },
      user: { name: 'Admin User', role: 'admin', permissions: %w[read write admin delete publish] }
    )
  end
end)

otto.add_auth_strategy('permission:upload', lambda do |req|
  # Upload permission auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  case token
  when 'demo_token', 'admin_token'
    user_data = if token == 'admin_token'
                  { name: 'Admin User', role: 'admin', permissions: %w[read write admin delete upload] }
                else
                  { name: 'Demo User', role: 'user', permissions: %w[read write upload] }
                end

    OpenStruct.new(
      session: { session_id: "#{token}_session", user_id: token == 'admin_token' ? 2 : 1 },
      user: user_data
    )
  end
end)

otto.add_auth_strategy('permission:read', lambda do |req|
  # Read permission auth strategy (most permissive)
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  case token
  when 'demo_token'
    OpenStruct.new(
      session: { session_id: 'demo_session_123', user_id: 1 },
      user: { name: 'Demo User', role: 'user', permissions: %w[read write] }
    )
  when 'admin_token'
    OpenStruct.new(
      session: { session_id: 'admin_session_456', user_id: 2 },
      user: { name: 'Admin User', role: 'admin', permissions: %w[read write admin delete] }
    )
  when 'read_token'
    OpenStruct.new(
      session: { session_id: 'read_session_999', user_id: 4 },
      user: { name: 'Reader User', role: 'reader', permissions: ['read'] }
    )
  end
end)

otto.add_auth_strategy('permission:analytics', lambda do |req|
  # Analytics permission auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  if token == 'admin_token'
    OpenStruct.new(
      session: { session_id: 'admin_session_456', user_id: 2 },
      user: { name: 'Admin User', role: 'admin', permissions: %w[read write admin analytics] }
    )
  end
end)

otto.add_auth_strategy('permission:process', lambda do |req|
  # Processing permission auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  case token
  when 'demo_token'
    OpenStruct.new(
      session: { session_id: 'demo_session_123', user_id: 1 },
      user: { name: 'Demo User', role: 'user', permissions: %w[read write process] }
    )
  when 'admin_token'
    OpenStruct.new(
      session: { session_id: 'admin_session_456', user_id: 2 },
      user: { name: 'Admin User', role: 'admin', permissions: %w[read write admin process] }
    )
  end
end)

otto.add_auth_strategy('permission:test', lambda do |req|
  # Test permission auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  if token == 'test_token'
    OpenStruct.new(
      session: { session_id: 'test_session_000', user_id: 5 },
      user: { name: 'Test User', role: 'tester', permissions: ['test'] }
    )
  end
end)

otto.add_auth_strategy('role:test', lambda do |req|
  # Test role auth strategy
  token = req.params['token'] || req.get_header('HTTP_AUTHORIZATION')
  if token == 'test_token'
    OpenStruct.new(
      session: { session_id: 'test_session_000', user_id: 5 },
      user: { name: 'Test User', role: 'test', permissions: ['test'] }
    )
  end
end)

otto.add_auth_strategy('api_key', lambda do |req|
  # API key auth strategy
  api_key = req.params['api_key'] || req.get_header('HTTP_X_API_KEY')
  if api_key == 'demo_api_key_123'
    OpenStruct.new(
      session: { api_session: 'api_session_abc' },
      user: { name: 'API Client', type: 'api', permissions: ['api_access'] }
    )
  end
end)

# Set error handlers
otto.not_found = lambda do |_env|
  AdvancedApp.not_found
end

otto.server_error = lambda do |_env, _error|
  AdvancedApp.server_error
end

run otto
