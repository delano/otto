# examples/advanced_routes/app/logic/v2/logic/processor.rb

module V2
  module Logic
    class Processor
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        @context = context
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
