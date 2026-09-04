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
- MCP rate limiting now applies to a custom ``http_endpoint``. The
  ``mcp_requests`` and ``mcp_tool_calls`` throttles read the endpoint from
  ``env['otto.mcp_http_endpoint']``, which Otto sets inside its own middleware
  stack, but ``Rack::Attack`` is mounted by the host app ahead of Otto, so the
  key was never present and the throttles fell back to ``/_mcp``. An MCP
  server on ``/api/mcp`` was never throttled. The endpoint now travels with the
  rate limiting configuration as ``mcp_http_endpoint``; the JSON-RPC 429 body
  and the ``[MCP]`` log prefix follow it. (#258)
- ``Otto.new`` reads the ``mcp_enabled``, ``mcp_http`` and ``mcp_stdio``
  gating keys through the MCP option normalizer, so
  ``Otto.new(routes, "mcp_enabled" => true, "auth_tokens" => [...])`` enables
  MCP. Previously the gating keys were read as Symbols only, so a String-keyed
  ``"mcp_enabled"`` silently enabled nothing while the String-keyed
  ``"auth_tokens"`` beside it was documented as accepted. (#258)
- ``Otto::MCP::Server#enable!`` raises ``ArgumentError`` when the server is
  already enabled. A second call appended a new route and middleware without
  removing the first set, so ``enable!(http_endpoint: '/new')`` after
  ``enable!(http_endpoint: '/old', auth_tokens: [...])`` left ``/old`` routed
  and unauthenticated. Pass every MCP option in a single ``Otto.new`` or
  ``enable_mcp!`` call. (#258)

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
- String-keyed MCP options silently disabled authentication.
  ``Otto::MCP::Options.normalize`` symbolized keys for the unrecognized-key
  check but read only Symbol keys afterwards, so
  ``enable_mcp!("auth_tokens" => [...])`` was accepted, normalized to no
  tokens, and served the endpoint unauthenticated. Keys are now symbolized once
  before anything is read, in both the constructor and ``#enable_mcp!`` scopes.
  A String key and its Symbol twin with different values raise the same
  ``Conflicting MCP options`` ``ArgumentError`` as any other alias pair. (#258)
- ``Otto#enable_mcp!`` accepted the constructor-only gating keys
  ``mcp_enabled``, ``mcp_http`` and ``mcp_stdio`` and ignored them, so
  ``enable_mcp!(mcp_http: false)`` still mounted the endpoint. They are only
  read by ``Otto.new`` and are now rejected by ``#enable_mcp!`` with an
  ``ArgumentError`` that says so. The constructor still tolerates them. (#258)
- ``MiddlewareStack#validate_mcp_middleware_order`` only checked the first
  occurrence of each MCP middleware class, so a stack executing rate limiting,
  then authentication, then a second rate limiter produced no warning. It now
  warns when any occurrence of the outer middleware executes after any
  occurrence of the inner one. (#258)

Added
-----

- ``Otto::MCP::Options.normalize`` is the single normalization path for MCP
  options, shared by the constructor and ``#enable_mcp!``. Both entry points
  accept the same canonical keys plus their ``mcp_``-prefixed spellings
  (``mcp_endpoint`` for ``http_endpoint``, ``mcp_auth_tokens`` for
  ``auth_tokens``, and so on) and ``tool_calls_per_minute`` for
  ``tools_per_minute``. (#258)

Changed
-------

- **Behavior change:** the bare generic names ``endpoint``, ``validation``,
  ``rate_limiting``, ``http`` and ``stdio`` are not MCP options and
  ``#enable_mcp!`` now rejects them. ``endpoint:`` and ``http:`` appeared in
  the documented ``otto.enable_mcp!(http: true, endpoint: '/api/mcp')`` but
  were never read, ``rate_limiting:`` is Otto's own general rate-limiting
  option (a Hash) and collided with the MCP flag, and none of the five ever
  had an effect. Use ``http_endpoint``, ``enable_validation`` and
  ``enable_rate_limiting``, or their ``mcp_`` spellings; ``http:`` and
  ``stdio:`` have no ``#enable_mcp!`` replacement because it always enables the
  HTTP endpoint (``Otto.new(mcp_http:, mcp_stdio:)`` is unchanged). (#258)
- **Behavior change:** ``Otto.new`` (constructor scope) ignores keys it does not
  recognize, since it is handed the whole options hash, but an unrecognized
  ``mcp_``-prefixed key raises ``ArgumentError``. ``Otto#enable_mcp!``
  (explicit scope) is STRICT: any unrecognized key raises ``ArgumentError``
  listing the recognized options. ``enable_mcp!(auth_token: 'x')`` used to be
  dropped in silence, leaving the endpoint unauthenticated; it now fails at
  boot. (#258)
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
- The follow-up review that found the String-keyed option bypass, the
  custom-endpoint throttle bypass, the double-enable hole, the gating-key
  no-op and the String-keyed gating keys was produced by GPT-5.6 Sol. (#258)
