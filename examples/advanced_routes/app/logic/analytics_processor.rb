# examples/advanced_routes/app/logic/analytics_processor.rb

module Analytics
  class Processor
    attr_reader :context, :params, :locale

    def initialize(context, params, locale)
      @context = context
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
