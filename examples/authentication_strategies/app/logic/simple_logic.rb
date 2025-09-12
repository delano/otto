# Simple Logic class
class SimpleLogic
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def raise_concerns
    # Logic classes can implement this method for validation
  end

  def process
    {
      message: 'Simple logic processed',
      params: @params,
      user: @context.user_name || 'anonymous',
      locale: @locale,
      authenticated: @context.authenticated?,
    }
  end

  def response_data
    { logic_result: process }
  end
end
