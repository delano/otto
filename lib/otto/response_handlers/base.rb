# frozen_string_literal: true

class Otto
  module ResponseHandlers
    # Base response handler class
    class BaseHandler
      def self.handle(result, response, context = {})
        raise NotImplementedError, 'Subclasses must implement handle method'
      end

      def self.ensure_status_set(response, default_status = 200)
        response.status = default_status unless response.status && response.status != 0
      end
    end
  end
end
