Security
--------

- ``auth=``, ``role=``, and ``csrf=`` on an ``MCP`` or ``TOOL`` line are now
  rejected. Otto parsed these options but never applied them: the MCP server
  registered the resource or tool without an authentication, role, or CSRF
  check, so any request the MCP endpoint accepted could read the resource or
  call the tool. **Behavior change**: when MCP is enabled as the routes file
  loads (``Otto.new(path, mcp_enabled: true)``, or ``enable_mcp!`` before
  ``load``), a routes file that sets any of these options on an ``MCP`` or
  ``TOOL`` line raises ``Otto::RouteDefinitionError`` and the application
  fails to boot. Remove the options and require a token for the endpoint with
  ``mcp_auth_tokens``. When MCP is not enabled as the file loads, Otto logs
  and skips every ``MCP`` and ``TOOL`` line, as before, without checking its
  options. See the `MCP guide <docs/guides/mcp.md>`__.

Changed
-------

- Any other ``key=value`` option on an ``MCP`` or ``TOOL`` line, such as
  ``response=json``, now logs a ``MCP/tool route option not applied`` warning
  when the routes file loads with MCP enabled. The option still loads, but the
  MCP server reads only the resource URI or tool name and the handler, so it
  has no effect.

Fixed
-----

- An MCP endpoint configured with ``auth_tokens`` (``mcp_auth_tokens``) no
  longer fails every request with ``FrozenError`` once the configuration
  freezes. ``Otto#call`` freezes it on the first request outside the test
  suite. The token middleware is registered with the security config as its
  argument, so freezing reached ``Otto::Security::Config#deep_freeze!`` a
  second time, and the second call raised. A second call now returns the
  frozen config, as ``Otto::Core::Freezable#deep_freeze!`` already did.

Documentation
-------------

- The MCP guide's multi-step example now calls ``enable_mcp!`` before it
  loads the routes file. It called ``Otto.new('routes')`` first, so Otto
  logged and skipped every ``MCP`` and ``TOOL`` line and the endpoint served
  no resources or tools.
