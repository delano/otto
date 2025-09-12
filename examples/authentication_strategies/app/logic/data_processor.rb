# Data processing Logic classes
class DataProcessor
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      processed_data: @params,
      processor: 'DataProcessor',
      timestamp: Time.now.iso8601,
    }
  end

  def response_data
    { data_processing: process }
  end
end
