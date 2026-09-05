# Model Context Protocol (MCP)

`Otto::MCP` adds one JSON-RPC 2.0 HTTP endpoint to an Otto application. An MCP
client can use that endpoint to initialize a connection, list registered
resources and tools, read resources, and call tools. The default endpoint is
`POST /_mcp`.

MCP is opt-in. It can invoke the handlers that you register, so require bearer
tokens before exposing the endpoint outside a trusted local environment.

## Before you start

MCP validation and rate limiting are enabled by default. Add their optional
dependencies to the application's `Gemfile` before enabling MCP:

```ruby
# Gemfile
gem 'json_schemer', '~> 2.0'
gem 'rack-attack', '~> 6.7'
```

Mount `Rack::Attack` in the Rack application. Without it, the configured MCP
rate limits are not enforced.

```ruby
# config.ru
use Rack::Attack
run otto
```

If a dependency is missing, enabling its corresponding feature raises
`Otto::OptionalDependencyError`. You may disable validation or rate limiting
with `enable_validation: false` or `enable_rate_limiting: false`, but doing so
removes that protection.

Configure MCP during boot, before Otto serves its first request. See
[configuration freezing](configuration_freezing.md) for the lifecycle rule.

## Enable a protected endpoint

Use `mcp_enabled: true` when constructing the application. Use
`ENV.fetch('MCP_TOKEN')` without a default so a missing deployment secret stops
boot instead of creating an open endpoint.

```ruby
# config.ru
require 'otto'
require_relative 'app'

otto = Otto.new('routes',
  mcp_enabled: true,
  mcp_auth_tokens: [ENV.fetch('MCP_TOKEN')],
  mcp_requests_per_minute: 120,
  mcp_tool_calls_per_minute: 30,
)

use Rack::Attack
run otto
```

The endpoint is `POST /_mcp` unless `mcp_endpoint:` (or `http_endpoint:`) sets
another slash-prefixed path. `mcp_enabled?` returns `true` after MCP has been
enabled.

For multi-step boot configuration, call `enable_mcp!` instead:

```ruby
otto = Otto.new('routes')
otto.enable_mcp!(
  http_endpoint: '/api/mcp',
  auth_tokens: [ENV.fetch('MCP_TOKEN')],
)
```

Enable MCP only once per `Otto` instance. A second call raises `ArgumentError`;
provide all MCP settings in the first call.

## Register resources and tools

Declare resources and tools in the normal Otto routes file. The initial verb
and path are required by the route-file grammar, but they do not create HTTP
routes for these declarations. Otto registers the MCP definition that follows
them. The single MCP HTTP endpoint remains the only transport route.

```text
# routes
GET  /mcp/users        MCP users AppMCP.users
POST /mcp/create-user  TOOL create_user AppMCP.create_user
```

`MCP` registers a resource. Its resource URI is `users`: Otto removes one
leading slash from the declaration. The handler must be a zero-argument class
method. Otto returns its value as text with the `text/plain` MIME type.

`TOOL` registers a tool. Its handler is a class method that receives
`arguments` and the Rack `env`:

```ruby
# app.rb
require 'json'

class AppMCP
  def self.users
    JSON.generate(users: [{ id: 1, name: 'Ada' }])
  end

  def self.create_user(arguments, _env)
    "Created user: #{arguments.fetch('name')}"
  end
end
```

A resource declaration currently supplies its name, description, and MIME type
automatically: the resource URI determines the name, descriptions are generated
from the URI or tool name, and resources use `text/plain`. Tool declarations
currently advertise an empty input schema. A tool still receives the
`params.arguments` object supplied by the client, so validate its fields in the
handler before using them.

## Call the endpoint

Every request must be a JSON-RPC 2.0 `POST` with
`Content-Type: application/json`. A request needs `jsonrpc`, `id`, and
`method`; `params`, when present, must be an object.

Pass a configured token in either header. `Authorization` is checked first.

```text
Authorization: Bearer <token>
X-MCP-Token: <token>
```

Initialize the connection:

```sh
curl -sS -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer s3cret' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

Replace `s3cret` in these requests with a configured token. A successful
response has the same `id` and a `result` containing the protocol version,
supported capabilities, and server information.

After registering the preceding routes, list the available resources and tools:

```sh
curl -sS -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer s3cret' \
  -d '{"jsonrpc":"2.0","id":2,"method":"resources/list","params":{}}'

curl -sS -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer s3cret' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
```

Read the `users` resource or call the `create_user` tool:

```sh
curl -sS -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer s3cret' \
  -d '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"users"}}'

curl -sS -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer s3cret' \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"create_user","arguments":{"name":"Ada"}}}'
```

## Authentication

`auth_tokens:` accepts a string or an array of strings. The endpoint accepts a
request when the token matches any configured token. Missing, malformed, or
unknown credentials return HTTP `401` and this JSON-RPC error:

```json
{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Unauthorized","data":"Valid token required"}}
```

Supplying `nil`, a blank string, or an otherwise empty token value raises
`ArgumentError`. An explicit empty array means no token authentication is
mounted, so do not use it as a way to disable access.

For a deliberate localhost-only endpoint, omit `auth_tokens:` and acknowledge
that choice explicitly:

```ruby
otto.enable_mcp!(allow_unauthenticated: true)
```

This option only suppresses Otto's unauthenticated-endpoint warning; it does
not add or remove authentication. An open endpoint lets any caller list and
invoke every registered MCP resource and tool.

## Configuration reference

Both enablement forms accept the canonical option names below and the listed
`mcp_` aliases. Keys may be Symbols or Strings. Providing two spellings of one
option with different values raises `ArgumentError`.

| Option | Alias | Default | Effect |
| --- | --- | --- | --- |
| `http_endpoint` | `mcp_endpoint` | `'/_mcp'` | Slash-prefixed endpoint path. |
| `auth_tokens` | `mcp_auth_tokens` | `[]` | String or array of bearer tokens. |
| `enable_validation` | `mcp_validation` | `true` | Validates the JSON-RPC request envelope. |
| `enable_rate_limiting` | `mcp_rate_limiting` | `true` | Enables MCP rate-limit configuration. |
| `requests_per_minute` | `mcp_requests_per_minute` | `60` | Per-client-IP limit for all MCP endpoint requests. |
| `tools_per_minute` | `tool_calls_per_minute`, `mcp_tool_calls_per_minute` | `20` | Additional per-client-IP limit for `tools/call`. |
| `allow_unauthenticated` | `mcp_allow_unauthenticated` | `false` | Acknowledges an intentionally open endpoint. |

Limits must be positive integers. Endpoint paths must be strings beginning with
`/`; tokens must be non-blank strings; and all flags must be exactly `true` or
`false`. Invalid values fail at boot with `ArgumentError`.

`mcp_enabled`, `mcp_http`, and `mcp_stdio` are constructor-only gating options:

| Constructor option | Effect |
| --- | --- |
| `mcp_enabled: true` | Creates the MCP server and enables its HTTP endpoint. |
| `mcp_http: false` | Does not register the HTTP endpoint or its middleware. It is useful only with another MCP gate such as `mcp_enabled: true`. |
| `mcp_stdio: true` | Creates the MCP server, but Otto does not provide an stdio transport. Because HTTP is enabled by default, also set `mcp_http: false` to avoid enabling HTTP. |

`enable_mcp!` always enables HTTP and rejects these gating options. It is strict:
unknown keys, including common near-misses such as `auth_token:`, raise
`ArgumentError`. The `Otto.new` constructor ignores unknown non-MCP options but
rejects unknown `mcp_`-prefixed options.

## Rate limiting and validation

Rate limits use a rolling 60-second period. `tools_per_minute` is additional to
`requests_per_minute`, not a replacement. The guards run in this order:

1. Rate limiting
2. Token authentication
3. JSON-schema validation

Therefore, a malformed request without a valid token receives `401` instead of
a validation response. Set either feature to `false` only when you accept the
resulting exposure.

MCP guards match the configured endpoint exactly, using Otto's normalized path.
A sibling such as `/admin` beside an endpoint at `/a` is not challenged,
validated, or counted. A configured trailing slash is accepted with or without
the trailing slash.

When Otto is mounted under a Rack path prefix, mount `Rack::Attack` inside the
same `map` block so it receives the same `PATH_INFO` that Otto routes:

```ruby
# config.ru
map '/api' do
  use Rack::Attack
  run otto # An endpoint at /_mcp is reached at POST /api/_mcp.
end
```

`Rack::Attack` configuration is process-global. Separate Otto applications in
the same process get independent MCP counters when their endpoint paths differ.
Applications that share the same endpoint path also share its throttle
configuration and counters; use distinct endpoint paths when isolation matters.

If general Otto rate limiting is also enabled, its `Rack::Attack` responder
replaces MCP's JSON-RPC-specific `429` response. Do not rely on the MCP error
body in that combined configuration.

## Errors and limits

| Situation | HTTP status and JSON-RPC code |
| --- | --- |
| Missing or invalid bearer token | `401`, `-32000` (`Unauthorized`) |
| Invalid JSON, request envelope, HTTP method, or content type | `400`, `-32700` or `-32600` |
| Unknown protocol method or invalid method parameters | `400`, `-32601` or `-32602` |
| Unknown resource or tool | `404`, `-32001` or `-32002` |
| Resource or tool handler raises | `500`, `-32603`; details are logged, not returned to the client |
| MCP rate limit exceeded | `429`, `-32000` unless general Otto rate limiting overrides the response body |

Otto currently provides HTTP transport only. It does not implement an stdio
transport, resource subscriptions, or resource-list change notifications.
