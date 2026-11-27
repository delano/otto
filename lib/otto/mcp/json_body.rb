# lib/otto/mcp/json_body.rb
#
# frozen_string_literal: true

require 'json'

class Otto
  module MCP
    # Parses the body of a request to the MCP endpoint.
    #
    # Ruby's JSON parser accepts two things a response cannot be built from:
    # bytes that are not UTF-8 inside a string, and a number such as 1e400
    # that overflows to Infinity. Either one later raises when Otto echoes an
    # id, digests arguments or validates them. Both are refused here, where
    # the request can still be answered as malformed.
    module JSONBody
      # @param text [String] the request body
      # @return [Object] the parsed value
      # @raise [JSON::ParserError] if the body is not UTF-8, is not JSON, or
      #   has a number that is not finite
      def self.parse(text)
        text = text.to_s
        text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
        raise JSON::ParserError, 'body is not valid UTF-8' unless text.valid_encoding?

        data = JSON.parse(text)
        raise JSON::ParserError, 'body has a number that is not finite' unless finite?(data)

        data
      end

      # @api private
      def self.finite?(value)
        case value
        when Hash then value.each_value.all? { |item| finite?(item) }
        when Array then value.all? { |item| finite?(item) }
        when Float then value.finite?
        else true
        end
      end
      private_class_method :finite?
    end
  end
end
