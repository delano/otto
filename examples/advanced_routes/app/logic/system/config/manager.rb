# frozen_string_literal: true

module System
  module Config
    class Manager
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        @context = context
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
