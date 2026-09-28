Security
--------

- A routes file that sets ``auth=``, ``role=``, or ``csrf=`` on an ``MCP`` or
  ``TOOL`` line now fails to load with ``Otto::RouteDefinitionError``. Otto
  parsed these options but never applied them: the MCP server registered the
  resource or tool without an authentication, role, or CSRF check, so any
  request the MCP endpoint accepted could read the resource or call the tool.
  Remove these options from ``MCP`` and ``TOOL`` lines and require a token for
  the endpoint with ``mcp_auth_tokens``. Other options on these lines still
  load. See the `MCP guide <docs/guides/mcp.md>`__.
