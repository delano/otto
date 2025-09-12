require 'json'
require 'time'

class ApiController
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

  def self.webhook_handler
    [200, { 'content-type' => 'application/json' }, ['{"message": "Webhook processed (CSRF exempt)"}']]
  end

  def self.external_update
    [200, { 'content-type' => 'application/json' }, ['{"message": "External update processed"}']]
  end

  def self.cleanup_data
    [200, { 'content-type' => 'application/json' }, ['{"message": "Data cleanup completed"}']]
  end

  def self.admin_users
    [200, { 'content-type' => 'application/json' }, ['{"users": [], "admin_view": true}']]
  end

  def self.create_admin_user
    [201, { 'content-type' => 'application/json' }, ['{"message": "Admin user created"}']]
  end

  def self.update_user
    [200, { 'content-type' => 'application/json' }, ['{"message": "User updated"}']]
  end

  def self.delete_user
    [204, {}, ['']]
  end

  def self.secure_data
    [200, { 'content-type' => 'application/json' }, ['{"secure": "data", "authenticated": true}']]
  end

  def self.secure_upload
    [200, { 'content-type' => 'application/json' }, ['{"message": "Secure upload completed"}']]
  end

  def self.api_private
    [200, { 'content-type' => 'application/json' }, ['{"message": "Private API accessed with api_key auth"}']]
  end
end
