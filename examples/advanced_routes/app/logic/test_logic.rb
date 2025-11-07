# examples/advanced_routes/app/logic/test_logic.rb

class TestLogic
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      test: 'Logic class test',
      params_received: @params,
      processing_complete: true,
    }
  end

  def response_data
    { test_logic: process }
  end
end
