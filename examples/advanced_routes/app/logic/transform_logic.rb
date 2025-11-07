# examples/advanced_routes/app/logic/transform_logic.rb

class TransformLogic
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      transformation: 'Complete',
      input_size: @params.to_s.length,
      output_format: 'json',
    }
  end

  def response_data
    { transform_result: process }
  end
end
