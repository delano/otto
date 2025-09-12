module V2
  module Logic
    module Admin
      class Dashboard
        attr_reader :context, :params, :locale

        def initialize(context, params, locale)
          @context = context
          @params = params
          @locale = locale
        end

        def process
          {
            dashboard: 'V2 Admin Dashboard',
            version: '2.0',
            admin_features: ['user_management', 'system_config', 'reports'],
            current_user: @context.user_name || 'admin',
          }
        end

        def response_data
          { v2_admin_dashboard: process }
        end
      end
    end
  end
end
