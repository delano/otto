# examples/advanced_routes/app/logic/data_processor.rb

class DataProcessor
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      processed: 'Data processing complete',
      input_params: @params.keys,
      timestamp: Time.now.iso8601,
      authenticated: @context.authenticated?,
      user_id: @context.user_id,
    }
  end

  def response_data
    { data_processor: process }
  end
end
