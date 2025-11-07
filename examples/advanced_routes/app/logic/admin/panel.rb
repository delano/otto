# frozen_string_literal: true

module Admin
  class Panel
    attr_reader :context, :params, :locale

    def initialize(context, params, locale)
      @context = context
      @params = params
      @locale = locale
    end

    def process
      {
        admin_panel: 'Logic processed',
        namespace: 'Admin',
        access_level: 'admin',
        authenticated: @context.authenticated?,
        has_admin_role: @context.has_role?('admin'),
      }
    end

    def response_data
      { admin_panel_logic: process }
    end
  end
end
