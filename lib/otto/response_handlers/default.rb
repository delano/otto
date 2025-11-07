# lib/otto/response_handlers/default.rb
#
# frozen_string_literal: true

require_relative 'base'

class Otto
  module ResponseHandlers
    # Default handler that preserves existing Otto behavior
    class DefaultHandler < BaseHandler
      def self.handle(_result, response, _context = {})
        # Otto's default behavior - let the route handler manage the response
        # This handler does nothing, preserving existing behavior
        ensure_status_set(response, 200)
      end
    end
  end
end
