Security
--------

- Fixed the Otto constructor silently dropping ``auth_tokens`` when MCP was
  enabled via ``Otto.new(routes, mcp_enabled: true, auth_tokens: [...])``. The
  MCP HTTP endpoint started unauthenticated, letting any caller list and invoke
  every registered MCP tool and resource. All MCP options passed to the
  constructor now reach the MCP server. (#258)
- ``Otto::MCP::Auth::TokenMiddleware`` now fails closed: when it is mounted but
  no authenticator is configured, it returns ``401`` instead of passing the
  request through unauthenticated. (#258)
- Otto now logs a warning at boot when the MCP HTTP endpoint is enabled without
  any ``auth_tokens``. Pass ``allow_unauthenticated: true`` to acknowledge an
  intentionally open endpoint and silence the warning; it changes no access
  check. (#258)

Fixed
-----

- **MCP middleware ran in the reverse of the documented and intended order.**
  ``MiddlewareStack`` stores entries in the reverse of execution order, and the
  MCP server used its ``:first`` / ``:last`` position hints as though they were
  execution order. The real order was schema validation, then token
  authentication, then rate limiting — so unauthenticated callers reached the
  JSON schema validator, and the rate limiter shed load last instead of first.
  MCP middleware now executes rate limiting, then authentication, then
  validation. (#258)
- ``MiddlewareStack#validate_mcp_middleware_order`` compared raw array indices
  as if they were execution order, so it warned about correct stacks and stayed
  silent about inverted ones. It now reasons over ``#execution_order``. (#258)
- ``Otto#enable_mcp!(auth_tokens: [...])`` no longer raises ``NoMethodError``;
  ``Otto::Security::Config`` accepts the MCP authenticator. (#258)
- MCP ``requests_per_minute`` and ``tools_per_minute`` are now applied. The
  hardcoded 60 and 20 defaults previously overrode configured values. (#258)

Added
-----

- ``Otto::MCP::Options.normalize`` is the single normalization path for MCP
  options, shared by the constructor and ``#enable_mcp!``. Both entry points
  accept the same canonical keys plus historical aliases (``mcp_endpoint`` and
  ``endpoint`` for ``http_endpoint``, ``mcp_auth_tokens`` for ``auth_tokens``,
  ``tool_calls_per_minute`` for ``tools_per_minute``, and others). (#258)

Changed
-------

- **Behavior change:** the two entry points now have explicitly different option
  vocabularies. ``Otto.new`` (constructor scope) reads the canonical keys, their
  ``mcp_``-prefixed spellings, and the documented bare keys ``auth_tokens``,
  ``requests_per_minute``, ``tools_per_minute`` and ``allow_unauthenticated``.
  It deliberately does NOT read bare ``endpoint``, ``validation`` or
  ``rate_limiting``: those names are generic, and ``rate_limiting:`` is Otto's
  own general rate-limiting option, which previously collided with the MCP flag.
  Everything else in the constructor hash is ignored, but an unrecognized
  ``mcp_``-prefixed key still raises ``ArgumentError``. (#258)
- **Behavior change:** ``Otto#enable_mcp!`` (explicit scope) accepts the full
  alias set — canonical keys, the bare ``endpoint`` / ``validation`` /
  ``rate_limiting`` spellings, and the ``mcp_`` spellings — and is now STRICT:
  any other key raises ``ArgumentError`` listing the recognized options.
  ``enable_mcp!(auth_token: 'x')`` used to be dropped in silence, leaving the
  endpoint unauthenticated; it now fails at boot. (#258)
- **Behavior change:** supplying two spellings of the same option with
  conflicting values raises ``ArgumentError``. (#258)
- **Behavior change:** ``auth_tokens`` that is supplied but resolves to no
  usable token raises ``ArgumentError``. ``auth_tokens: ENV['MCP_TOKEN']`` with
  the variable unset is ``nil``, which mounts no authentication middleware and
  exposes the endpoint; empty and whitespace-only tokens are rejected for the
  same reason. Omitting the key still defaults to no tokens with the boot
  warning, and a literal ``auth_tokens: []`` remains accepted so normalization
  stays idempotent. (#258)

Documentation
-------------

- Added ``docs/guides/mcp.md``: enabling MCP from the constructor and from
  ``#enable_mcp!``, the full option table with aliases and defaults, bearer
  token authentication and ``401`` behavior, the unauthenticated warning, rate
  limiting and validation, and error cases. (#258)
- Updated ``examples/mcp_demo`` to document that its configured tokens and rate
  limits are now enforced, and to send the bearer token in every request. (#258)
- ``docs/guides/mcp.md`` now documents the MCP middleware execution order, and
  notes that the JSON-RPC formatted 429 body only applies when Otto's general
  rate limiting is off: both limiters assign
  ``Rack::Attack.throttled_responder`` and the general one is registered last.
  (#258)

AI Assistance
-------------

- Option normalization design, fail-closed authentication review, and
  documentation developed with AI assistance. (#258)
