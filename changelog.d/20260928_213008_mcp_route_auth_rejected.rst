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

Fixed
-----

- An MCP endpoint configured with ``auth_tokens`` (``mcp_auth_tokens``) no
  longer fails every request with ``FrozenError`` once the configuration
  freezes. ``Otto#call`` freezes it on the first request outside the test
  suite. The token middleware is registered with the security config as its
  argument, so freezing reached ``Otto::Security::Config#deep_freeze!`` a
  second time, and the second call raised. A second call now returns the
  frozen config, as ``Otto::Core::Freezable#deep_freeze!`` already did.
