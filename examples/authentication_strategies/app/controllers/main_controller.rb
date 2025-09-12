require 'json'
require 'time'

class MainController
  def self.index
    [200, { 'content-type' => 'text/html' }, ['<h1>Authentication Strategies Example</h1>']]
  end

  def self.receive_feedback
    [200, { 'content-type' => 'text/plain' }, ['Feedback received']]
  end

  def self.dashboard
    [200, { 'content-type' => 'text/html' }, ['<h1>Dashboard</h1><p>Welcome to your dashboard!</p>']]
  end

  def self.reports
    [200, { 'content-type' => 'text/html' }, ['<h1>Reports</h1><p>Admin-only reports section</p>']]
  end

  def self.not_found
    [404, { 'content-type' => 'text/html' }, ['<h1>404 - Page Not Found</h1><p>Advanced routes example</p>']]
  end

  def self.server_error
    [500, { 'content-type' => 'text/html' }, ['<h1>500 - Server Error</h1><p>Something went wrong</p>']]
  end
end
