# frozen_string_literal: true

class UploadLogic
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      upload: 'Processing complete',
      csrf_exempt: true,
      files_processed: @params.keys.count,
    }
  end

  def response_data
    { upload_result: process }
  end
end
