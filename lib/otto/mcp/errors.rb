# lib/otto/mcp/errors.rb
#
# frozen_string_literal: true

require_relative '../errors'

class Otto
  module MCP
    # Raised by {Otto::MCP::Registry#call_tool} when the requested tool name is
    # not registered. Distinct from a tool that exists but fails during
    # execution: the former is a named-entity lookup failure (JSON-RPC -32002,
    # HTTP 404), the latter an execution fault (-32603, HTTP 500).
    class ToolNotFoundError < Otto::NotFoundError; end
  end
end
