# frozen_string_literal: true

module Admin
  module Logic
    class Manager
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        @context = context
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
