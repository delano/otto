# examples/advanced_routes/app/logic/complex/business/handler.rb

module Complex
  module Business
    class Handler
      attr_reader :context, :params, :locale

      def initialize(context, params, locale)
        @context = context
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
