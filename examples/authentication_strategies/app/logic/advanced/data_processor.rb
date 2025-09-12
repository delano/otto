module Advanced
  class DataProcessor
    attr_reader :context, :params, :locale

    def initialize(context, params, locale)
      @context = context
      @params = params
      @locale = locale
    end

    def process
      {
        advanced_processing: 'Complete',
        features: ['authentication', 'permissions', 'json_response'],
        user_context: {
          authenticated: @context.authenticated?,
          permissions: @context.permissions,
          roles: @context.roles,
        },
        request_data: @params,
        auth_method: @context.auth_method,
      }
    end

    def response_data
      { advanced_processor: process }
    end
  end
end
