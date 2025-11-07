# examples/advanced_routes/app/logic/data_logic.rb

class DataLogic
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      data_logic: 'Processed',
      response_format: 'json',
      input_data: @params,
    }
  end

  def response_data
    { data_logic_result: process }
  end
end
