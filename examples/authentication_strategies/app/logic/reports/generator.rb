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
        report: 'Generated report data',
        user_permissions: @context.permissions,
        locale: @locale,
        authenticated: @context.authenticated?,
        has_read_permission: @context.has_permission?('read'),
      }
    end

    def response_data
      { reports: process }
    end
  end
end
