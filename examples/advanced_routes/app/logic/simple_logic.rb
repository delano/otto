# examples/advanced_routes/app/logic/simple_logic.rb

class SimpleLogic
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      message: 'Simple logic processed',
      params: @params,
      locale: @locale,
      authenticated: @context.authenticated?,
      user: @context.user_name,
    }
  end

  def response_data
    { simple_logic: process }
  end
end
