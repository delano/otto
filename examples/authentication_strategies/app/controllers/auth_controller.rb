require 'json'

class AuthController
  def self.show_profile
    [200, { 'content-type' => 'text/html' }, ['<h1>User Profile</h1>']]
  end

  def self.update_profile
    [200, { 'content-type' => 'text/plain' }, ['Profile updated']]
  end

  def self.admin_panel
    [200, { 'content-type' => 'text/html' }, ['<h1>Admin Panel</h1><p>Role: admin required</p>']]
  end

  def self.moderator_panel
    [200, { 'content-type' => 'text/html' }, ['<h1>Moderator Panel</h1><p>Role: moderator required</p>']]
  end

  def self.edit_content
    [200, { 'content-type' => 'text/html' }, ['<h1>Edit Content</h1><p>Permission: write required</p>']]
  end

  def self.publish_content
    [200, { 'content-type' => 'text/plain' }, ['Content published (permission: publish required)']]
  end

  def self.login_redirect
    [302, { 'location' => '/profile' }, ['']]
  end

  def self.logout_redirect
    [302, { 'location' => '/' }, ['']]
  end
end
