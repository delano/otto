# examples/advanced_routes/app/logic/nested/feature/logic.rb

module Nested
  module Feature
    class Logic
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        @context = context
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
