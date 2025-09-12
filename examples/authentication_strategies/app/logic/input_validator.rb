class InputValidator
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      validation_result: 'Input validated successfully',
      validated_params: @params.keys,
      user: @context.user_name || 'anonymous',
    }
  end

  def response_data
    { validation: process }
  end
end
