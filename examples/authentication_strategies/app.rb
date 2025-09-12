# frozen_string_literal: true

require 'json'

# Main application class demonstrating advanced Otto routes
class AdvancedApp
  # ========================================
  # BASIC ROUTES
  # ========================================

  def self.index
    [200, { 'content-type' => 'text/html' }, ['<h1>Advanced Routes Example</h1>']]
  end

  def self.receive_feedback
    [200, { 'content-type' => 'text/plain' }, ['Feedback received']]
  end

  # ========================================
  # AUTHENTICATION ROUTES
  # ========================================

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

  def self.api_private
    [200, { 'content-type' => 'application/json' }, ['{"message": "Private API accessed with api_key auth"}']]
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

  def self.dashboard
    [200, { 'content-type' => 'text/html' }, ['<h1>Dashboard</h1><p>Welcome to your dashboard!</p>']]
  end

  def self.reports
    [200, { 'content-type' => 'text/html' }, ['<h1>Reports</h1><p>Admin-only reports section</p>']]
  end

  def self.login_redirect
    [302, { 'location' => '/profile' }, ['']]
  end

  def self.logout_redirect
    [302, { 'location' => '/' }, ['']]
  end

  def self.flexible_data
    # This demonstrates auto response type - will return JSON or HTML based on Accept header
    data = { message: 'This is flexible data', timestamp: Time.now.iso8601 }
    [200, { 'content-type' => 'application/json' }, [data.to_json]]
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

  def self.update_settings
    [200, { 'content-type' => 'text/plain' }, ['Settings updated (CSRF protected)']]
  end

  def self.change_password
    [200, { 'content-type' => 'text/plain' }, ['Password changed (CSRF protected)']]
  end

  # ========================================
  # MULTIPLE PARAMETER COMBINATIONS
  # ========================================

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

  # ========================================
  # NAMESPACED CLASS ROUTES
  # ========================================

  def self.show_config
    [200, { 'content-type' => 'application/json' }, ['{"environment": "production", "admin_access": true}']]
  end

  def self.complex_handler
    [200, { 'content-type' => 'application/json' }, ['{"message": "Complex handler with all parameters"}']]
  end

  # ========================================
  # ERROR HANDLERS
  # ========================================

  def self.not_found
    [404, { 'content-type' => 'text/html' }, ['<h1>404 - Page Not Found</h1><p>Advanced routes example</p>']]
  end

  def self.server_error
    [500, { 'content-type' => 'text/html' }, ['<h1>500 - Server Error</h1><p>Something went wrong</p>']]
  end

  # ========================================
  # TESTING ROUTES
  # ========================================

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
end

# ========================================
# LOGIC CLASSES (New in v1.5.0+)
# ========================================

# Simple Logic class
class SimpleLogic
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def raise_concerns
    # Logic classes can implement this method for validation
  end

  def process
    {
      message: 'Simple logic processed',
      params: @params,
      user: @user&.dig('name') || 'anonymous',
      locale: @locale,
    }
  end

  def response_data
    { logic_result: process }
  end
end

# Namespaced Logic classes
module Admin
  module Logic
    class Panel
      attr_reader :session, :user, :params, :locale

      def initialize(session, user, params, locale)
        @session = session
        @user = user
        @params = params
        @locale = locale
      end

      def process
        {
          admin_panel: 'Admin logic processed',
          user_role: @user&.dig('role') || 'unknown',
          session_id: @session&.dig('session_id'),
        }
      end

      def response_data
        { admin_logic: process }
      end
    end
  end
end

module Reports
  class Generator
    attr_reader :session, :user, :params, :locale

    def initialize(session, user, params, locale)
      @session = session
      @user = user
      @params = params
      @locale = locale
    end

    def process
      {
        report: 'Generated report data',
        user_permissions: @user&.dig('permissions') || [],
        locale: @locale,
      }
    end

    def response_data
      { reports: process }
    end
  end
end

# Data processing Logic classes
class DataProcessor
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def process
    {
      processed_data: @params,
      processor: 'DataProcessor',
      timestamp: Time.now.iso8601,
    }
  end

  def response_data
    { data_processing: process }
  end
end

class InputValidator
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def process
    {
      validation_result: 'Input validated successfully',
      validated_params: @params.keys,
      user: @user&.dig('name') || 'anonymous',
    }
  end

  def response_data
    { validation: process }
  end
end

# Complex namespaced Logic classes
module V2
  module Logic
    module Admin
      class Dashboard
        attr_reader :session, :user, :params, :locale

        def initialize(session, user, params, locale)
          @session = session
          @user = user
          @params = params
          @locale = locale
        end

        def process
          {
            dashboard: 'V2 Admin Dashboard',
            version: '2.0',
            admin_features: ['user_management', 'system_config', 'reports'],
            current_user: @user&.dig('name') || 'admin',
          }
        end

        def response_data
          { v2_admin_dashboard: process }
        end
      end
    end
  end
end

module Analytics
  class Processor
    attr_reader :session, :user, :params, :locale

    def initialize(session, user, params, locale)
      @session = session
      @user = user
      @params = params
      @locale = locale
    end

    def process
      {
        analytics: 'Analytics data processed',
        metrics: {
          page_views: 12_345,
          unique_users: 1_234,
          conversion_rate: 0.045,
        },
        period: @params['period'] || 'last_30_days',
      }
    end

    def response_data
      { analytics: process }
    end
  end
end

# More namespaced classes for demonstration
module V2
  module Admin
    class Panel
      def self.show
        [200, { 'content-type' => 'text/html' }, ['<h1>V2 Admin Panel</h1><p>Class method implementation</p>']]
      end
    end

    class Settings
      def self.update
        [200, { 'content-type' => 'application/json' }, ['{"message": "V2 Admin settings updated"}']]
      end
    end
  end
end

module Modules
  class AuthHandler
    def process
      [200, { 'content-type' => 'text/html' }, ['<h1>Auth Handler</h1><p>Instance method implementation</p>']]
    end
  end

  class DataValidator
    def validate
      [200, { 'content-type' => 'application/json' }, ['{"message": "Data validation completed"}']]
    end
  end
end

module Advanced
  class DataProcessor
    attr_reader :session, :user, :params, :locale

    def initialize(session, user, params, locale)
      @session = session
      @user = user
      @params = params
      @locale = locale
    end

    def process
      {
        advanced_processing: 'Complete',
        features: ['authentication', 'permissions', 'json_response'],
        user_context: {
          authenticated: !@user.nil?,
          permissions: @user&.dig('permissions') || [],
        },
        request_data: @params,
      }
    end

    def response_data
      { advanced_processor: process }
    end
  end
end
