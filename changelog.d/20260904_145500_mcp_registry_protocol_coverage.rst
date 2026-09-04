Changed
-------

- An unknown MCP tool is now reported as 404 instead of 500 (#257).
  ``Registry#call_tool`` raised a bare ``RuntimeError`` for an unregistered
  tool, which the protocol could only report as an internal error. It now
  raises ``Otto::MCP::ToolNotFoundError`` (an ``Otto::NotFoundError``), which
  the protocol maps to JSON-RPC -32002 / HTTP 404, leaving -32603 / 500 for
  tools that exist but fail.

- A crashing MCP resource handler is now reported as 500 instead of 404
  (#257). ``Registry#read_resource`` rescued every ``StandardError`` and
  returned ``nil``, making a failing handler indistinguishable from an
  unregistered URI. The error still logs but now propagates, so the protocol
  returns -32603 / 500, matching tool-call behaviour.

- MCP internal errors no longer echo the exception message (#257). Resource
  and tool handler failures returned the raw ``e.message`` in the JSON-RPC
  ``error.data`` field, which can carry filesystem paths (``Errno::*``) or
  constant-resolution internals. The detail is logged and the response now
  carries a fixed ``"Resource read failed"`` / ``"Tool execution failed"``.

Fixed
-----

- Correct the MCP JSON-RPC error code to HTTP status mapping (#257). The
  ``case`` in ``Otto::MCP::Protocol#error_response`` had two dead branches: the
  ``-32700..-32600`` range already matched method-not-found and invalid-params
  before their own branches were reached, and the server-error range was
  written descending (``-32000..-32099``) so it never matched anything. The
  mapping is now an explicit ``ERROR_STATUS_MAP`` constant with a documented
  policy: protocol-level faults (-32700, -32600, -32601, -32602) are 400,
  unknown named entities (-32001, -32002) are 404, and execution faults
  (-32603 and the ``-32099..-32000`` server range) are 500.

- Add direct specs for ``Otto::MCP::Registry``, ``Otto::MCP::Protocol`` and
  ``Otto::MCP::RouteParser``, which previously had no coverage of their own
  (#257).
