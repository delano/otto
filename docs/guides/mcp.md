# Model Context Protocol (MCP)

`Otto::MCP` adds a single JSON-RPC 2.0 HTTP endpoint (default `POST /_mcp`) to an
Otto app, so a CLI or an AI client can list and invoke the resources and tools
your routes file declares. The module is loaded but inert until you enable it.

The endpoint is unauthenticated unless you configure bearer tokens. Read
[Authentication](#authentication) before exposing it beyond localhost.

## Enable MCP

Two entry points. Both normalize through `Otto::MCP::Options.normalize`, so the
same options, spellings, and defaults apply — they differ only in strictness.
See [Options](#options).

At construction:

```ruby
require 'otto'

otto = Otto.new('routes',
                mcp_enabled: true,
                auth_tokens: ['s3cret'],
                requests_per_minute: 120)

run otto
```

After construction, before the app is frozen or serves its first request:

```ruby
otto = Otto.new('routes')
otto.enable_mcp!(http_endpoint: '/api/mcp', auth_tokens: ['s3cret'])
otto.mcp_enabled? # => true
```

Before Otto 2.9.0 the constructor silently discarded everything but the
endpoint, and `enable_mcp!(auth_tokens: ...)` raised `NoMethodError` (#258). If
you worked around either bug, remove the workaround.

## Options

Both entry points accept the same spellings: each canonical key and its
`mcp_`-prefixed variant. The prefix exists so the constructor can pick MCP
settings out of an options hash that also configures the rest of Otto; it is
accepted by `enable_mcp!` too, so one hash can feed either entry point. The
bare generic names `endpoint:`, `validation:`, and `rate_limiting:` are **not**
MCP options: `rate_limiting:` is Otto's own general rate-limiting option and
carries a Hash, and the other two were documented before Otto 2.9.0 but never
read.

`enable_mcp!` configures MCP and nothing else, so it is **strict**: any key it
does not recognize raises `ArgumentError` listing the ones it does. A typo such
as `enable_mcp!(auth_token: 'x')` (singular) used to be dropped in silence —
which is exactly how an endpoint ends up unauthenticated — and now fails at
boot.

`Otto.new` forwards its *entire* options hash, most of which configures other
subsystems, so the constructor scope ignores keys it does not recognize. An
unrecognized `mcp_`-prefixed key still raises, since such a key can only have
been meant for MCP.

| Canonical key | Accepted spellings | Type | Default | Effect |
| --- | --- | --- | --- | --- |
| `http_endpoint` | `http_endpoint`, `mcp_endpoint` | String path starting with `/` | `'/_mcp'` | Path the `POST` MCP route is mounted at. |
| `auth_tokens` | `auth_tokens`, `mcp_auth_tokens` | Array of String (a bare String is wrapped) | `[]` | Accepted bearer tokens. Empty means no authentication middleware is mounted. |
| `enable_validation` | `enable_validation`, `mcp_validation` | Boolean | `true` | Mounts JSON schema validation of MCP requests, last in the MCP middleware order. |
| `enable_rate_limiting` | `enable_rate_limiting`, `mcp_rate_limiting` | Boolean | `true` | Mounts the MCP rate-limit middleware first. |
| `requests_per_minute` | `requests_per_minute`, `mcp_requests_per_minute` | positive Integer | `60` | Per-IP limit on all requests to the MCP endpoint. |
| `tools_per_minute` | `tools_per_minute`, `tool_calls_per_minute`, `mcp_tool_calls_per_minute` | positive Integer | `20` | Per-IP limit on `tools/call` requests. |
| `allow_unauthenticated` | `allow_unauthenticated`, `mcp_allow_unauthenticated` | Boolean | `false` | Acknowledges an intentionally token-less endpoint and silences the boot warning. Does not itself change access. |

Supplying two spellings of the same option with different values raises
`ArgumentError`; identical values are accepted.

Three further keys are recognized on the **constructor only**, and gate whether
MCP is enabled rather than configuring it:

| Key | Effect |
| --- | --- |
| `mcp_enabled: true` | Creates the MCP server and enables the HTTP endpoint. |
| `mcp_http: false` | Creates the MCP server but does **not** enable the HTTP endpoint (no route, no middleware). Defaults to enabled. |
| `mcp_stdio: true` | Creates the MCP server. Otto ships no stdio transport, so this does nothing on its own — and because `mcp_http` defaults to true, it also enables the HTTP endpoint. Pair it with `mcp_http: false` if that is not what you want. |

Wrong types fail loud: a non-`String` token, a non-Integer or non-positive
per-minute limit, an endpoint that is not a `/`-prefixed String, or a
non-boolean flag each raise `ArgumentError` at boot.

## Authentication

Pass `auth_tokens:` to require a bearer token. Otto then mounts
`Otto::MCP::Auth::TokenMiddleware`, which guards every path beginning with the
configured endpoint. A request may present its token either way:

```
Authorization: Bearer s3cret
X-MCP-Token: s3cret
```

`Authorization: Bearer` is checked first. Tokens are compared in constant time
against the whole configured set, so neither match position nor membership leaks
via timing.

A missing, malformed, or unknown token gets a JSON-RPC error envelope:

```json
{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Unauthorized","data":"Valid token required"}}
```

with HTTP status `401`.

`auth_tokens` that is *supplied* but resolves to no usable token raises
`ArgumentError`. `auth_tokens: ENV['MCP_TOKEN']` with the variable unset is
`nil`, which would otherwise mount no auth middleware at all and serve the
endpoint to anyone; an empty or whitespace-only token is rejected for the same
reason, since no client could present it. To serve MCP without authentication
on purpose, omit `auth_tokens` entirely and pass `allow_unauthenticated: true`.

The middleware **fails closed**: if it is mounted but the authenticator is
missing from the security config, it returns `401` rather than passing the
request through (#258). It is only mounted when `auth_tokens` is non-empty, so
an empty token list means the endpoint is open, not that it is closed.

### The unauthenticated warning

Enabling the HTTP endpoint with no tokens logs, unconditionally (not gated on
`Otto.debug`):

```
[MCP] HTTP endpoint /_mcp is enabled without authentication: any caller can list
and invoke MCP tools and resources. Pass auth_tokens: ['<token>'] to require a
bearer token, or allow_unauthenticated: true to acknowledge this intentionally.
```

This is the intended posture for a localhost-only development endpoint. To keep
that posture and silence the warning, say so explicitly:

```ruby
otto.enable_mcp!(allow_unauthenticated: true)
```

`allow_unauthenticated: true` only suppresses the warning. It does not relax or
tighten any check, and it is ignored when tokens are configured.

## Rate limiting and validation

With `enable_rate_limiting` (the default), Otto publishes `requests_per_minute`
and `tools_per_minute` into the security config's rate-limiting configuration,
where the MCP rate-limit middleware reads them. Configured values are now
honoured; before the #258 fix the hardcoded 60/20 defaults always won.

Both limits are per client IP over a 60-second window. `tools_per_minute`
applies to `POST` requests whose JSON-RPC `method` is `tools/call`, and is
additional to `requests_per_minute`. Throttled MCP requests receive a JSON-RPC
formatted error rather than a bare Rack 429 body.

Note that the JSON-RPC 429 body only applies when Otto's *general* rate
limiting is off. Both rate limiters assign `Rack::Attack.throttled_responder`,
and the general one is registered last, so when you enable both, throttled MCP
requests get the general (plain-text or generic-JSON) 429 body instead.

With `enable_validation` (the default), incoming MCP requests are schema
validated after authentication and rate limiting — the expensive check runs
last, on requests that already proved themselves.

Set either to `false` to skip the corresponding middleware entirely.

### Middleware order

The three MCP middlewares execute in this order, outermost first:

1. **Rate limiting** — sheds excess load before anything else spends work.
2. **Token authentication** — rejects anonymous callers before bodies are parsed.
3. **Schema validation** — the expensive check, on requests that already passed
   the two above.

So an unauthenticated request with a malformed JSON-RPC body gets `401`, not a
validation error. Before Otto 2.9.0 the order was exactly inverted and the
validator ran first (#258).

## Try it

```sh
curl -sS -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer s3cret' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

Drop the `Authorization` header against a token-protected endpoint and the same
request returns `401` with the `Unauthorized` envelope above.

`examples/mcp_demo/` is a runnable version of this setup.

## Error cases

| Situation | Result |
| --- | --- |
| Unknown key passed to `enable_mcp!`, e.g. `auth_token: 'x'` | `ArgumentError` listing the unknown key and every recognized MCP option. This scope is strict. |
| Unknown `mcp_`-prefixed key passed to `Otto.new`, e.g. `mcp_tokens:` | Same `ArgumentError`. Non-`mcp_` keys are ignored there, since the constructor forwards its whole options hash. |
| Bare `endpoint:`, `validation:`, or `rate_limiting:` passed to `enable_mcp!` | `ArgumentError`; they are not MCP options. Use `http_endpoint`, `enable_validation`, `enable_rate_limiting`. Passed to `Otto.new` they are ignored by MCP like any other non-MCP key. |
| Two spellings of one option with different values, e.g. `http_endpoint: '/a', mcp_endpoint: '/b'` | `ArgumentError` naming the canonical option and the conflicting spellings. Identical values are accepted. |
| `auth_tokens:` supplied but empty, e.g. `ENV['MCP_TOKEN']` unset, `''`, `['']` | `ArgumentError`. Omit the key and pass `allow_unauthenticated: true` for a deliberately open endpoint. |
| `enable_mcp!` after the instance is frozen | Raises; configure MCP during boot. See [configuration freezing](configuration_freezing.md). |
| `POST` to the endpoint when MCP is not enabled | `404` with `{"error":"MCP not enabled"}`. |

The unknown-key rejection is deliberate: a typo in an MCP option used to be
dropped in silence, which is exactly how an endpoint ends up unauthenticated.
