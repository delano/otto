# examples/advanced_routes/app/logic/v2/logic/dashboard.rb

module V2
  module Logic
    class Dashboard
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        @context = context
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
  end
end
