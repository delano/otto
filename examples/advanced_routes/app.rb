# frozen_string_literal: true

require 'json'

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

# ========================================
# LOGIC CLASSES (New in v1.5.0+)
# ========================================

# Simple Logic classes
class SimpleLogic
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def process
    {
      message: 'Simple logic processed',
      params: @params,
      locale: @locale,
    }
  end

  def response_data
    { simple_logic: process }
  end
end

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
      processed: 'Data processing complete',
      input_params: @params.keys,
      timestamp: Time.now.iso8601,
    }
  end

  def response_data
    { data_processor: process }
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
      validation: 'Input validated successfully',
      validated_fields: @params.keys,
      locale: @locale,
    }
  end

  def response_data
    { validator: process }
  end
end

class DataLogic
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def process
    {
      data_logic: 'Processed',
      response_format: 'json',
      input_data: @params,
    }
  end

  def response_data
    { data_logic_result: process }
  end
end

class UploadLogic
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def process
    {
      upload: 'Processing complete',
      csrf_exempt: true,
      files_processed: @params.keys.count,
    }
  end

  def response_data
    { upload_result: process }
  end
end

class TransformLogic
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def process
    {
      transformation: 'Complete',
      input_size: @params.to_s.length,
      output_format: 'json',
    }
  end

  def response_data
    { transform_result: process }
  end
end

class TestLogic
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def process
    {
      test: 'Logic class test',
      params_received: @params,
      processing_complete: true,
    }
  end

  def response_data
    { test_logic: process }
  end
end

# ========================================
# NAMESPACED LOGIC CLASSES
# ========================================

module Admin
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
        admin_panel: 'Logic processed',
        namespace: 'Admin',
        access_level: 'admin',
      }
    end

    def response_data
      { admin_panel_logic: process }
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
        report_generation: 'Complete',
        namespace: 'Reports',
        data_points: 100,
      }
    end

    def response_data
      { report_generator: process }
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
        analytics: 'Processed',
        metrics: { users: 123, events: 456 },
        period: @params['period'] || 'today',
      }
    end

    def response_data
      { analytics_processor: process }
    end
  end
end

# Complex namespaced Logic classes
module V2
  module Logic
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
          v2_dashboard: 'Rendered',
          version: '2.0',
          features: ['metrics', 'charts', 'reports'],
        }
      end

      def response_data
        { v2_dashboard: process }
      end
    end

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
          v2_processor: 'Complete',
          csrf_exempt: true,
          processing_time: 0.05,
        }
      end

      def response_data
        { v2_processor: process }
      end
    end
  end
end

module Admin
  module Logic
    class Manager
      attr_reader :session, :user, :params, :locale

      def initialize(session, user, params, locale)
        @session = session
        @user = user
        @params = params
        @locale = locale
      end

      def process
        {
          admin_manager: 'Active',
          namespace: 'Admin::Logic',
          management_tools: ['users', 'settings', 'logs'],
        }
      end

      def response_data
        { admin_logic_manager: process }
      end
    end
  end
end

# Deeply nested Logic classes
module Nested
  module Feature
    class Logic
      attr_reader :session, :user, :params, :locale

      def initialize(session, user, params, locale)
        @session = session
        @user = user
        @params = params
        @locale = locale
      end

      def process
        {
          nested_feature: 'Processed',
          depth: 3,
          namespace: 'Nested::Feature',
        }
      end

      def response_data
        { nested_feature_logic: process }
      end
    end
  end
end

module Complex
  module Business
    class Handler
      attr_reader :session, :user, :params, :locale

      def initialize(session, user, params, locale)
        @session = session
        @user = user
        @params = params
        @locale = locale
      end

      def process
        {
          complex_business: 'Handled',
          namespace: 'Complex::Business',
          business_logic: 'executed',
        }
      end

      def response_data
        { complex_business_handler: process }
      end
    end
  end
end

module System
  module Config
    class Manager
      attr_reader :session, :user, :params, :locale

      def initialize(session, user, params, locale)
        @session = session
        @user = user
        @params = params
        @locale = locale
      end

      def process
        {
          system_config: 'Updated',
          namespace: 'System::Config',
          csrf_exempt: true,
        }
      end

      def response_data
        { system_config_manager: process }
      end
    end
  end
end

# ========================================
# NAMESPACED CLASS ROUTES
# ========================================

module V2
  class Admin
    def self.show
      [200, { 'content-type' => 'text/html' }, ['<h1>V2 Admin</h1><p>Class method implementation</p>']]
    end
  end

  class Config
    def self.update
      [200, { 'content-type' => 'application/json' }, ['{"message": "V2 config updated"}']]
    end
  end

  class Settings
    def self.modify
      [200, { 'content-type' => 'application/json' }, ['{"message": "V2 settings modified", "csrf": "exempt"}']]
    end
  end
end

module Modules
  class Auth
    def process
      [200, { 'content-type' => 'text/html' }, ['<h1>Auth Module</h1><p>Instance method implementation</p>']]
    end
  end

  class Validator
    def validate
      [200, { 'content-type' => 'application/json' }, ['{"validation": "passed", "module": "Validator"}']]
    end
  end

  class Transformer
    def transform
      [200, { 'content-type' => 'application/json' }, ['{"transformation": "complete", "csrf": "exempt"}']]
    end
  end
end

module Handlers
  class Static
    def self.serve
      [200, { 'content-type' => 'text/html' }, ['<h1>Static Handler</h1><p>Static content served</p>']]
    end
  end

  class Dynamic
    def process
      [200, { 'content-type' => 'application/json' }, ['{"handler": "dynamic", "processed": true}']]
    end
  end

  class Async
    def execute
      [200, { 'content-type' => 'application/json' }, ['{"execution": "async", "csrf": "exempt"}']]
    end
  end
end
