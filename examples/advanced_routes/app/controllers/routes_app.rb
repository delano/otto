# frozen_string_literal: true

require 'json'
require 'time'

# Main application class demonstrating advanced routes syntax
class RoutesApp
  # ========================================
  # BASIC ROUTES
  # ========================================

  def self.index
    [200, { 'content-type' => 'text/html' }, ['<h1>Advanced Routes Syntax Example</h1><p>Otto v1.5.0+ Features</p>']]
  end

  def self.receive_feedback
    [200, { 'content-type' => 'text/plain' }, ['Feedback received']]
  end

  # ========================================
  # RESPONSE TYPE ROUTES
  # ========================================

  def self.list_users
    users = [
      { id: 1, name: 'Alice', role: 'admin' },
      { id: 2, name: 'Bob', role: 'user' },
    ]
    [200, { 'content-type' => 'application/json' }, [users.to_json]]
  end

  def self.create_user
    [201, { 'content-type' => 'application/json' }, ['{"message": "User created", "id": 3}']]
  end

  def self.health_check
    [200, { 'content-type' => 'application/json' }, ['{"status": "healthy", "timestamp": "' + Time.now.iso8601 + '"}']]
  end

  def self.update_user
    [200, { 'content-type' => 'application/json' }, ['{"message": "User updated"}']]
  end

  def self.delete_user
    [204, {}, ['']]
  end

  def self.dashboard
    [200, { 'content-type' => 'text/html' }, ['<h1>Dashboard</h1><p>HTML view response</p>']]
  end

  def self.reports
    [200, { 'content-type' => 'text/html' }, ['<h1>Reports</h1><p>View response type demonstration</p>']]
  end

  def self.admin_panel
    [200, { 'content-type' => 'text/html' }, ['<h1>Admin Panel</h1><p>Administrative interface</p>']]
  end

  def self.login_redirect
    [302, { 'location' => '/dashboard' }, ['']]
  end

  def self.logout_redirect
    [302, { 'location' => '/' }, ['']]
  end

  def self.home_redirect
    [302, { 'location' => '/dashboard' }, ['']]
  end

  def self.flexible_data
    data = { message: 'This is flexible data', timestamp: Time.now.iso8601 }
    [200, { 'content-type' => 'application/json' }, [data.to_json]]
  end

  def self.flexible_content
    [200, { 'content-type' => 'application/json' }, ['{"content": "Auto response type", "format": "negotiated"}']]
  end

  # ========================================
  # CSRF ROUTES
  # ========================================

  def self.webhook_handler
    [200, { 'content-type' => 'application/json' }, ['{"message": "Webhook processed (CSRF exempt)"}']]
  end

  def self.external_update
    [200, { 'content-type' => 'application/json' }, ['{"message": "External update processed"}']]
  end

  def self.cleanup_data
    [200, { 'content-type' => 'application/json' }, ['{"message": "Data cleanup completed"}']]
  end

  def self.sync_data
    [200, { 'content-type' => 'application/json' }, ['{"message": "Data sync completed"}']]
  end

  def self.update_settings
    [200, { 'content-type' => 'text/plain' }, ['Settings updated (CSRF protected)']]
  end

  def self.change_password
    [200, { 'content-type' => 'text/plain' }, ['Password changed (CSRF protected)']]
  end

  def self.delete_profile
    [204, {}, ['']]
  end

  # ========================================
  # MULTIPLE PARAMETER COMBINATIONS
  # ========================================

  def self.api_data
    [200, { 'content-type' => 'application/json' }, ['{"api": "v1", "data": "response"}']]
  end

  def self.api_submit
    [201, { 'content-type' => 'application/json' }, ['{"message": "API submission processed"}']]
  end

  def self.api_update
    [200, { 'content-type' => 'application/json' }, ['{"message": "API update completed"}']]
  end

  def self.admin_dashboard
    [200, { 'content-type' => 'text/html' }, ['<h1>Admin Dashboard</h1><p>Administrative view</p>']]
  end

  def self.admin_settings
    [200, { 'content-type' => 'text/html' }, ['<h1>Admin Settings</h1><p>Settings updated</p>']]
  end

  def self.mixed_content
    [200, { 'content-type' => 'application/json' }, ['{"type": "mixed", "csrf": "exempt", "response": "auto"}']]
  end

  # ========================================
  # CUSTOM PARAMETERS
  # ========================================

  def self.show_config
    [200, { 'content-type' => 'application/json' }, ['{"environment": "production", "config": "displayed"}']]
  end

  def self.debug_info
    [200, { 'content-type' => 'application/json' }, ['{"environment": "development", "debug": true}']]
  end

  def self.update_config
    [200, { 'content-type' => 'application/json' }, ['{"message": "Config updated", "environment": "production"}']]
  end

  def self.feature_flags
    [200, { 'content-type' => 'application/json' }, ['{"feature": "advanced", "mode": "enabled", "flags": []}']]
  end

  def self.toggle_feature
    [200, { 'content-type' => 'application/json' }, ['{"feature": "beta", "mode": "test", "toggled": true}']]
  end

  # ========================================
  # PARAMETER VALUE VARIATIONS
  # ========================================

  def self.api_v1
    [200, { 'content-type' => 'application/json' }, ['{"version": "1.0", "api": "v1"}']]
  end

  def self.api_v2
    [200, { 'content-type' => 'application/json' }, ['{"version": "2.0", "api": "v2"}']]
  end

  def self.api_legacy
    [200, { 'content-type' => 'application/json' }, ['{"version": "legacy", "deprecated": true}']]
  end

  def self.complex_query
    [200, { 'content-type' => 'application/json' }, ['{"query": "complex", "filter": "key=value"}']]
  end

  def self.config_db
    [200, { 'content-type' => 'application/json' }, ['{"connection": "host=localhost", "configured": true}']]
  end

  # ========================================
  # ERROR HANDLERS
  # ========================================

  def self.not_found
    [404, { 'content-type' => 'text/html' }, ['<h1>404 - Page Not Found</h1><p>Advanced routes syntax example</p>']]
  end

  def self.server_error
    [500, { 'content-type' => 'text/html' }, ['<h1>500 - Server Error</h1><p>Something went wrong</p>']]
  end

  # ========================================
  # TESTING ROUTES
  # ========================================

  def self.test_json
    [200, { 'content-type' => 'application/json' }, ['{"test": "json", "response_type": "json"}']]
  end

  def self.test_view
    [200, { 'content-type' => 'text/html' }, ['<h1>Test View</h1><p>HTML view response</p>']]
  end

  def self.test_redirect
    [302, { 'location' => '/' }, ['']]
  end

  def self.test_auto
    [200, { 'content-type' => 'application/json' }, ['{"test": "auto", "response_type": "auto"}']]
  end

  def self.test_csrf
    [200, { 'content-type' => 'text/html' }, ['<h1>CSRF Test</h1><p>POST request (CSRF protected)</p>']]
  end

  def self.test_no_csrf
    [200, { 'content-type' => 'text/html' }, ['<h1>No CSRF Test</h1><p>POST request (CSRF exempt)</p>']]
  end

  def self.test_everything
    [200, { 'content-type' => 'application/json' }, ['{"message": "All parameters tested", "csrf": "exempt", "custom": "value"}']]
  end
end
