Security
--------

- ``http_endpoint`` (``mcp_endpoint``) must be a literal path. A path with a
  ``:name`` segment or a ``*`` raises ``ArgumentError`` when MCP is enabled.
  Otto routed such a path as a pattern, while the MCP authentication,
  validation and rate-limit guards compare the request path with the
  configured path exactly. A request for ``/acme/mcp`` therefore reached an
  endpoint configured as ``/:tenant/mcp`` without a token, and could list and
  call its tools. An application that used a pattern there should mount one
  literal endpoint and take the tenant from the authenticated caller.
