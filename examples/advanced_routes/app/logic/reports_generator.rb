# examples/advanced_routes/app/logic/reports_generator.rb

module Reports
  class Generator
    attr_reader :context, :params, :locale

    def initialize(context, params, locale)
      @context = context
      @params = params
      @locale = locale
    end

    def process
      {
        report_generation: 'Complete',
        namespace: 'Reports',
        data_points: 100,
        authenticated: @context.authenticated?,
        user_permissions: @context.permissions,
      }
    end

    def response_data
      { report_generator: process }
    end
  end
end
