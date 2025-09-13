require 'json'

class AuthController
  def self.login_form
    [200, { 'content-type' => 'text/html' }, ['<h1>Login</h1><p>Use ?token=demo_token, ?token=admin_token, or ?api_key=demo_api_key_123</p>']]
  end

  def self.login
    # In a real app, you'd handle login logic here.
    # For this demo, we redirect to the profile.
    [302, { 'location' => '/profile' }, ['']]
  end

  def self.show_profile
    [200, { 'content-type' => 'text/html' }, ['<h1>User Profile</h1><p>You are authenticated.</p>']]
  end

  def self.admin_panel
    [200, { 'content-type' => 'text/html' }, ['<h1>Admin Panel</h1><p>Role: admin required</p>']]
  end

  def self.edit_content
    [200, { 'content-type' => 'text/html' }, ['<h1>Edit Content</h1><p>Permission: write required</p>']]
  end

  def self.api_data
    [200, { 'content-type' => 'application/json' }, ['{"data": "This is some secret API data."}']]
  end
end
