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
        analytics: 'Analytics data processed',
        metrics: {
          page_views: 12_345,
          unique_users: 1_234,
          conversion_rate: 0.045,
        },
        period: @params['period'] || 'last_30_days',
      }
    end

    def response_data
      { analytics: process }
    end
  end
end
