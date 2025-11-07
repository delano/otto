# lib/otto/response_handlers/view.rb

require_relative 'base'

class Otto
  module ResponseHandlers
    # Handler for view/template responses
    class ViewHandler < BaseHandler
      def self.handle(result, response, context = {})
        if context[:logic_instance]&.respond_to?(:view)
          response.body = [context[:logic_instance].view.render]
          response['Content-Type'] = 'text/html' unless response['Content-Type']
        elsif result.respond_to?(:to_s)
          response.body = [result.to_s]
          response['Content-Type'] = 'text/html' unless response['Content-Type']
        else
          response.body = ['']
        end

        ensure_status_set(response, context[:status_code] || 200)
      end
    end
  end
end
