# frozen_string_literal: true

class InputValidator
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      validation: 'Input validated successfully',
      validated_fields: @params.keys,
      locale: @locale,
      authenticated: @context.authenticated?,
    }
  end

  def response_data
    { validator: process }
  end
end
