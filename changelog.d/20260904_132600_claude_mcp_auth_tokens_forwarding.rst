Security
--------

- Fixed MCP bearer-token authentication being silently omitted when configured
  through ``Otto.new`` or with String-keyed options. Deployments exposing MCP
  beyond a trusted local environment should upgrade and verify their
  ``auth_tokens`` configuration. Intentionally open endpoints now warn unless
  acknowledged with ``allow_unauthenticated: true``. See the `MCP guide
  <docs/guides/mcp.md>`__. (#258)

- MCP authentication now fails closed when its authenticator is unavailable.
  Authentication, validation, and rate limiting also apply only to the exact
  routed MCP endpoint. (#258)

- MCP rate limiting now honors configured limits and protects custom endpoints,
  Rack-mounted applications, and distinct MCP endpoints in the same process.
  Mount ``Rack::Attack`` inside the same ``map`` block as Otto, and use distinct
  endpoint paths when applications require isolated counters. (#258)

Changed
-------

- MCP options now accept String or Symbol keys consistently and fail at boot
  for unknown, conflicting, or invalid values. Constructor gating options must
  be exactly ``true`` or ``false``; nil or blank token values are rejected.
  Before upgrading, check option names against the `MCP guide
  <docs/guides/mcp.md>`__. (#258)

- ``enable_mcp!`` now rejects constructor-only gating options and repeated
  enablement. Pass all MCP settings in one ``Otto.new`` or ``enable_mcp!`` call.
  (#258)

- MCP ``Rack::Attack`` throttle names are now endpoint-qualified, such as
  ``mcp_requests:/_mcp`` and ``mcp_tool_calls:/_mcp``. Update integrations that
  inspect throttle names directly. (#258)

Fixed
-----

- MCP middleware now executes rate limiting, authentication, and schema
  validation in that order. Configured endpoints with a trailing slash are also
  routable. (#258)

- Repeated MCP rate-limit configuration no longer produces duplicate throttle
  log entries. (#258)

Documentation
-------------

- Added the `MCP guide <docs/guides/mcp.md>`__ covering secure enablement,
  supported options, authentication, validation, rate limiting, mounted
  applications, and error behavior. (#258)
