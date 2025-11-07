# lib/otto/response_handlers.rb
#
# frozen_string_literal: true

class Otto
  module ResponseHandlers
    require_relative 'response_handlers/base'
    require_relative 'response_handlers/json'
    require_relative 'response_handlers/redirect'
    require_relative 'response_handlers/view'
    require_relative 'response_handlers/default'
    require_relative 'response_handlers/auto'
    require_relative 'response_handlers/factory'
  end
end
