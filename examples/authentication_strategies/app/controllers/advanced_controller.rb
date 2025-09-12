class AdvancedController
  def self.show_config
    [200, { 'content-type' => 'application/json' }, ['{"environment": "production", "admin_access": true}']]
  end

  def self.complex_handler
    [200, { 'content-type' => 'application/json' }, ['{"message": "Complex handler with all parameters"}']]
  end

  def self.test_auth
    [200, { 'content-type' => 'application/json' }, ['{"test": "auth", "authenticated": true}']]
  end

  def self.test_roles
    [200, { 'content-type' => 'application/json' }, ['{"test": "roles", "role_required": "test"}']]
  end

  def self.test_permissions
    [200, { 'content-type' => 'application/json' }, ['{"test": "permissions", "permission_required": "test"}']]
  end

  def self.test_csrf
    [200, { 'content-type' => 'text/html' }, ['<h1>CSRF Test</h1><p>GET request</p>']]
  end

  def self.test_csrf_post
    [200, { 'content-type' => 'text/html' }, ['<h1>CSRF Test</h1><p>POST request (CSRF protected)</p>']]
  end

  def self.test_no_csrf
    [200, { 'content-type' => 'text/html' }, ['<h1>No CSRF Test</h1><p>POST request (CSRF exempt)</p>']]
  end

  def self.flexible_data
    # This demonstrates auto response type - will return JSON or HTML based on Accept header
    data = { message: 'This is flexible data', timestamp: Time.now.iso8601 }
    [200, { 'content-type' => 'application/json' }, [data.to_json]]
  end

  def self.update_settings
    [200, { 'content-type' => 'text/plain' }, ['Settings updated (CSRF protected)']]
  end

  def self.change_password
    [200, { 'content-type' => 'text/plain' }, ['Password changed (CSRF protected)']]
  end
end
