module Admin
  module Logic
    class Panel
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        @context = context
        @params = params
        @locale = locale
      end

      def process
        {
          admin_panel: 'Admin logic processed',
          user_role: @context.roles.first || 'unknown',
          session_id: @context.session_id,
          authenticated: @context.authenticated?,
          has_admin_role: @context.has_role?('admin'),
        }
      end

      def response_data
        { admin_logic: process }
      end
    end
  end
end
