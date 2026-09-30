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

Added
-----

- A resource handler declared on an ``MCP`` line can take one argument, the
  Rack env of the MCP request, so it can check permissions per request the
  way a tool handler can. A zero-argument handler is still called with no
  arguments. ``Otto::MCP::Registry#read_resource`` takes the env as an
  optional second argument and passes it to a registered handler that takes
  one argument. A handler that requires more than one argument, or a keyword
  argument, raises ``ArgumentError`` on read, which the endpoint reports as a
  JSON-RPC internal error. Before this, any handler that took an argument
  failed that way.

Changed
-------

- Any other ``key=value`` option on an ``MCP`` or ``TOOL`` line, such as
  ``response=json``, now logs a ``MCP/tool route option not applied`` warning
  when the routes file loads with MCP enabled. The option still loads, but the
  MCP server reads only the resource URI or tool name and the handler, so it
  has no effect.

Documentation
-------------

- The MCP guide's multi-step example now calls ``enable_mcp!`` before it
  loads the routes file. It called ``Otto.new('routes')`` first, so Otto
  logged and skipped every ``MCP`` and ``TOOL`` line and the endpoint served
  no resources or tools.
