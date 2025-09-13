# frozen_string_literal: true

require_relative 'base'

class Otto
  module ResponseHandlers
    # Handler for JSON responses
    class JSONHandler < BaseHandler
      def self.handle(result, response, context = {})
        response['Content-Type'] = 'application/json'

        # Determine the data to serialize
        data = if context[:logic_instance]&.respond_to?(:response_data)
                 context[:logic_instance].response_data
               elsif result.is_a?(Hash)
                 result
               elsif result.nil?
                 { success: true }
               else
                 { success: true, data: result }
               end

        response.body = [JSON.generate(data)]
        ensure_status_set(response, context[:status_code] || 200)
      end
    end
  end
end
