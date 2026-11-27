# lib/otto/mcp/errors.rb
#
# frozen_string_literal: true

require_relative '../errors'

class Otto
  module MCP
    # JSON-RPC error codes for refusals that MCP does not define a code for.
    # They sit outside the range JSON-RPC reserves (-32768 to -32000), which
    # is where MCP 2026-07-28 asks for new codes to be allocated, and mirror
    # the HTTP status of the response they travel in. Clients act on the HTTP
    # status and the WWW-Authenticate header; the code is for diagnostics.
    #
    # A static-token endpoint's 401 and the rate limiter's 429 predate these
    # and keep -32000.
    UNAUTHORIZED = 401
    FORBIDDEN    = 403

    # Raised by {Otto::MCP::Registry#call_tool} when the requested tool name is
    # not registered. Distinct from a tool that exists but fails during
    # execution: the former is a named-entity lookup failure (JSON-RPC -32002,
    # HTTP 404), the latter an execution fault (-32603, HTTP 500).
    class ToolNotFoundError < Otto::NotFoundError; end

    # Raised by a tool handler to report a failure the caller can act on.
    #
    # The message is part of the tool's result: Otto returns it to the client
    # as text with +isError: true+, so it reaches the model. Write it for that
    # reader and never put a secret, a credential or an internal detail in it.
    # Any other exception a handler raises is answered with a fixed message
    # and its own message is not returned or logged.
    class ToolError < StandardError; end

    # Raised by {Otto::MCP::Registry} when the caller's verified scopes do not
    # cover the scopes a tool or resource requires. The protocol answers it
    # with HTTP 403 and an +insufficient_scope+ challenge.
    class InsufficientScopeError < StandardError
      # @return [Array<String>] every scope the tool or resource requires
      attr_reader :required_scopes

      # @param required_scopes [Array<String>]
      def initialize(required_scopes)
        @required_scopes = required_scopes.dup.freeze
        super('Insufficient scope')
      end
    end

    # Raised when a +requestState+ value fails verification: it was altered,
    # it expired, or it was issued to another principal or for another request.
    class InvalidRequestStateError < Otto::BadRequestError; end

    # Raised when a tool's return value does not conform to its output schema.
    # The value is withheld from the client.
    class OutputValidationError < StandardError
      # @return [Array<Hash>] the failed keyword and schema location of each
      #   violation; never the offending value
      attr_reader :violations

      # @param violations [Array<Hash>]
      def initialize(violations)
        @violations = violations
        super('Tool result does not conform to its output schema')
      end
    end

    # Raised when a tool answers with an input request the endpoint cannot
    # deliver safely, such as a URL elicitation with no verified caller to
    # bind it to.
    class InputRequestError < StandardError; end
  end
end
