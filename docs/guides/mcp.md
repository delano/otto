# Model Context Protocol (MCP)

`Otto::MCP` adds one JSON-RPC 2.0 HTTP endpoint to an Otto application. An MCP
client uses that endpoint to list registered resources and tools, read
resources, and call tools. The default endpoint is `POST /_mcp`.

MCP is opt-in. It can invoke the handlers that you register, so require
authentication before exposing the endpoint outside a trusted local
environment.

An endpoint serves MCP revision `2024-11-05` unless `protocol_versions` selects
another. The first half of this guide describes that default, which is what
Otto served before the option existed. The second half describes what the
newer options add:

- [Declare a tool in Ruby](#declare-a-tool-in-ruby): schemas that Otto
  enforces on every call.
- [Authenticate callers with an authenticator](#authenticate-callers-with-an-authenticator):
  a verified caller and per-tool scopes.
- [Serve MCP 2026-07-28](#serve-mcp-2026-07-28): the revision without an
  `initialize` handshake.
- [Hosted endpoints](#hosted-endpoints): one option that refuses to boot
  without the settings a public endpoint needs.
- [Ask the person for input through a page](#ask-the-person-for-input-through-a-page):
  a tool that sends the person to a URL instead of taking a secret through
  the conversation.

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
removes that protection. A tool registered with `register_mcp_tool` needs
`json_schemer` whatever `enable_validation` is set to.

Configure MCP during boot, before Otto serves its first request. See
[configuration freezing](configuration_freezing.md) for the lifecycle rule.
Registered tools and resources freeze with the rest of the configuration:
after the first request, none can be added, replaced or removed.

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
another slash-prefixed path. The path must be literal. A `:name` segment or a
`*`, which Otto would route as a pattern, raises `ArgumentError`: the MCP
guards compare the path exactly, so they would not apply to the requests such
a pattern matched. `mcp_enabled?` returns `true` after MCP has been enabled.

For multi-step boot configuration, construct Otto without a routes file, call
`enable_mcp!`, then load the routes file:

```ruby
otto = Otto.new
otto.enable_mcp!(
  http_endpoint: '/api/mcp',
  auth_tokens: [ENV.fetch('MCP_TOKEN')],
)
otto.load('routes')
```

Otto registers `MCP` and `TOOL` lines only while a routes file loads, and only
if MCP is already enabled. `Otto.new('routes')` followed by `enable_mcp!` loads
the file first: Otto logs an error for each `MCP` and `TOOL` line, skips it,
and the endpoint serves no resources or tools.

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
leading slash from the declaration. The handler is a class method that takes
no arguments, or one argument: the Rack `env` of the MCP request. A handler
that requires more than one argument, or a keyword argument, fails the read
with a JSON-RPC internal error. Otto returns the handler's value as text with
the `text/plain` MIME type.

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

A resource declaration supplies its name, description, and MIME type
automatically: the resource URI determines the name, descriptions are generated
from the URI or tool name, and resources use `text/plain`. A `TOOL` line
advertises an empty input schema, and Otto does not check the arguments of a
tool registered this way. The tool receives the `params.arguments` object
supplied by the client, so validate its fields in the handler before using
them, or [declare the tool in Ruby](#declare-a-tool-in-ruby) instead.

`MCP` and `TOOL` declarations cannot use the `auth=`, `role=`, or `csrf=` route
options. Otto does not run route-level authentication, role, or CSRF checks
for resources and tools. When MCP is enabled as the routes file loads, a line
that sets any of these options raises `Otto::RouteDefinitionError` and the
application fails to boot:

```text
# Rejected when the routes file loads with MCP enabled:
POST /mcp/delete-user  TOOL delete_user AppMCP.delete_user auth=session role=admin
```

When MCP is not enabled as the file loads, Otto logs and skips every `MCP` and
`TOOL` line, as described above, without checking its options.

Any other `key=value` option on an `MCP` or `TOOL` line, such as
`response=json`, still loads, but Otto logs a `MCP/tool route option not
applied` warning for it. The MCP server reads only the resource URI or tool
name and the handler, so these options have no effect.

Use `mcp_auth_tokens` to require a token for the MCP endpoint (see
[Authentication](#authentication)). A request that passes the token check can
list, read, and call every resource and tool registered from a route line, so
check permissions inside the handler of any resource or tool that needs them.
Both receive the Rack `env` of the MCP request: a tool handler always, a
resource handler when it takes one argument.

### Declare a tool in Ruby

`register_mcp_tool` registers a tool together with the schemas Otto enforces
for it. Call it after MCP is enabled and before the first request.

```ruby
otto.enable_mcp!(auth_tokens: [ENV.fetch('MCP_TOKEN')])

otto.register_mcp_tool('create_user',
  description: 'Create a user account.',
  input_schema: {
    type: 'object',
    properties: { name: { type: 'string', maxLength: 80 } },
    required: ['name'],
  },
  output_schema: {
    type: 'object',
    properties: { id: { type: 'integer' } },
    required: ['id'],
    additionalProperties: false,
  },
) do |arguments, _env|
  { id: Users.create(arguments.fetch('name')).id }
end
```

The handler is the block, a callable passed as the second argument, or a
String that names a class method, such as `'AppMCP.create_user'`. It receives
`arguments` and the Rack `env`.

| Keyword | Required | Effect |
| --- | --- | --- |
| `description:` | yes | Shown to the client and the model. |
| `input_schema:` | yes | JSON Schema for `arguments`. Its root `type` must be `object`. |
| `output_schema:` | on a hosted endpoint | JSON Schema for the handler's return value. |
| `scopes:` | on a hosted endpoint | Scopes a caller must have. See [scopes](#require-scopes-for-a-tool-or-resource). |
| `title:` | no | Display name. |
| `annotations:` | no | Behavior hints such as `readOnlyHint`, passed to the client unchanged. |

A tool name is 1 to 128 letters, digits, underscores, hyphens and dots, and a
name can be registered once. A definition that Otto cannot enforce raises
`ArgumentError` at registration: an invalid JSON Schema, a `$ref` that does
not resolve inside the schema, a `$ref` to a network address, or an
`x-mcp-header` annotation. Otto does not fetch remote schemas and does not
implement the `Mcp-Param-*` request headers.

A declared tool cannot be replaced, and neither can a resource that requires
scopes. A `TOOL` or `MCP` route line that names one raises
`Otto::RouteDefinitionError` and stops the boot, so a later registration
cannot drop the schemas or scopes of an earlier one.

On every call to a declared tool:

1. **Arguments are checked against `input_schema` before the handler runs.**
   When the schema does not set `additionalProperties` at its root, Otto adds
   `additionalProperties: false` and advertises the schema that way, so an
   argument the schema does not name is refused. Set `additionalProperties:
   true` to accept other arguments. A call with invalid arguments returns a
   tool result with `isError: true` whose text names each location and rule,
   and never a value:

   ```json
   {"content":[{"type":"text","text":"Invalid arguments for tool create_user: object property at `/role` is a disallowed additional property"}],"isError":true}
   ```

2. **With an `output_schema`, the return value is checked before it is sent.**
   Otto converts the value to JSON types and returns it as `structuredContent`
   and as a text block that contains the same JSON. A value that does not
   conform is never sent. The client receives a JSON-RPC internal error, and
   Otto logs the code `tool_output_invalid` with the failed keyword and its
   location in the schema.

3. **Without an `output_schema`, the return value's `to_s` is the text result.**

Report a failure the caller can act on by raising `Otto::MCP::ToolError`. Its
message becomes the text of a result with `isError: true`, so it reaches the
model. Write it for that reader:

```ruby
raise Otto::MCP::ToolError, 'That name is taken. Choose another.'
```

Any other exception produces a JSON-RPC internal error with a fixed message.
Otto logs the exception class, a code (`tool_failed`), an `error_id` and a
sanitized backtrace. It does not log or return the exception's message, which
can contain whatever the handler was working with. This applies to tools and
resources from route lines too.

`register_mcp_resource` registers a resource from Ruby:

```ruby
otto.register_mcp_resource('policy/retention', description: 'Retention policy') do
  File.read('config/retention.md')
end
```

It accepts `name:` (default: the last segment of the URI), `mime_type:`
(default: `text/plain`) and `scopes:`. The handler takes no argument or the
Rack `env`. A URI can be registered this way once.

## Call the endpoint

This section shows requests under `2024-11-05`. For `2026-07-28`, see
[Serve MCP 2026-07-28](#serve-mcp-2026-07-28).

Every request must be a JSON-RPC 2.0 `POST` with
`Content-Type: application/json`. A request needs `jsonrpc`, `id`, and
`method`; `params`, when present, must be an object. The body must be UTF-8,
and a number in it must be finite: `1e400`, which Ruby's JSON parser reads as
`Infinity`, is refused as invalid JSON.

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

An endpoint authenticates in one of two ways: with static tokens
(`auth_tokens:`), described here, or with an
[authenticator](#authenticate-callers-with-an-authenticator). Setting both
raises `ArgumentError`.

`auth_tokens:` accepts a string or an array of strings. The endpoint accepts a
request when the token matches any configured token. Missing, malformed, or
unknown credentials return HTTP `401` and this JSON-RPC error:

```json
{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Unauthorized","data":"Valid token required"}}
```

Supplying `nil`, a blank string, or an otherwise empty token value raises
`ArgumentError`. An explicit empty array means no token authentication is
mounted, so do not use it as a way to disable access.

A static token identifies no one. Anyone with a token can list, read and
call everything, and a tool or resource cannot require scopes on such an
endpoint: registering one raises `ArgumentError`, because no caller could ever
satisfy it.

For a deliberate localhost-only endpoint, omit `auth_tokens:` and acknowledge
that choice explicitly:

```ruby
otto.enable_mcp!(allow_unauthenticated: true)
```

This option only suppresses Otto's unauthenticated-endpoint warning; it does
not add or remove authentication. An open endpoint lets any caller list and
invoke every registered MCP resource and tool.

### Authenticate callers with an authenticator

An authenticator tells Otto who is calling. It is any object that responds to
`call(token, env)`. Otto reads the bearer token from the request and passes it
in. The authenticator verifies the token and returns an
`Otto::MCP::Auth::Context` for a token it accepts, or `nil` for one it rejects.

```ruby
verifier = lambda do |token, _env|
  verified = AccessTokens.verify(token) # your code: signature, expiry, issuer, revocation
  next nil unless verified

  Otto::MCP::Auth::Context.new(
    subject: verified['sub'],        # required: who the token was issued for
    client_id: verified['client_id'],
    tenant: verified['org'],
    scopes: verified['scope'],       # 'a b', or an Array
    audience: verified['aud'],       # every resource the token was issued for
    issuer: verified['iss'],         # needed when more than one server issues tokens
  )
end

otto.enable_mcp!(authenticator: verifier)
```

How Otto treats the request and the authenticator's answer:

- Otto takes the token from `Authorization: Bearer <token>` and from nowhere
  else. It does not read `X-MCP-Token` or a query parameter. The scheme is
  matched without regard to case. A header that is missing, uses another
  scheme, is malformed, or has a token longer than 4096 bytes is refused
  without calling the authenticator.
- A returned `Context` is stored in `env['otto.mcp.auth']`. Any value already
  under that key is removed first. The protocol handler uses a context only
  when its own authenticator produced it on this request, so a context cannot
  arrive from an outer application, from another endpoint, or on a request
  that did not pass the authentication middleware. An endpoint with no
  authenticator discards the key.
- A return value other than a `Context`, `nil` or `false` raises `TypeError`.
  When the authenticator raises, Otto raises `Otto::MCP::AuthenticatorError`
  in its place. Both are answered with `500`: an outage in the token store is
  never reported as a refusal or as a success.
- `Otto::MCP::AuthenticatorError` has the class and backtrace of the original
  exception and not its message. An authenticator works with the token, and
  its exceptions can quote it, so the message is kept out of the log. The
  original is the error's `cause`. Register an error handler for
  `Otto::MCP::AuthenticatorError` to map such failures to another status.
- `issuer:` is optional. Give it when the endpoint accepts tokens from more
  than one authorization server: two servers can issue the same `subject`,
  and the issuer is part of what Otto binds a `requestState` to.
- A refused request gets `401` and a `WWW-Authenticate: Bearer` challenge. The
  challenge has `error="invalid_token"` when the request sent a Bearer
  credential, names `scopes_supported` when that option is set, and names the
  metadata document when `resource_uri` is set. No part of the request is
  echoed in it.
- Otto does not log or store the token.

An authenticator passed to `Otto.new` as `mcp_authenticator:` is frozen with
the rest of the options at the first request, as authentication strategies
are. Give it no state that it changes afterwards, or pass it to `enable_mcp!`.

### Require scopes for a tool or resource

`scopes:` on `register_mcp_tool` or `register_mcp_resource` lists the scopes a
caller must have. Each is an OAuth scope token.

```ruby
otto.register_mcp_tool('delete_user',
  description: 'Delete a user account.',
  input_schema: { type: 'object', properties: { id: { type: 'integer' } }, required: ['id'] },
  scopes: ['users:write'],
) { |arguments, env| Users.delete(arguments.fetch('id'), by: env['otto.mcp.auth'].subject) }
```

- `tools/list` and `resources/list` return only what the caller's scopes
  cover.
- `tools/call` and `resources/read` check the scopes again, whatever the lists
  returned, so naming a tool that was left out of the list does not reach its
  handler. The check is made where the handler is invoked, for both protocol
  revisions.
- A caller who lacks a scope gets `403` with
  `WWW-Authenticate: Bearer error="insufficient_scope", scope="..."` naming
  every scope the tool requires, and the JSON-RPC error `403` (`Forbidden`)
  with the same list in `data.requiredScopes`. Otto logs the refusal with the
  tool name and the client ID.
- A tool or resource with no scopes is available to every caller the endpoint
  admits.

Scopes say which callers may use a tool at all. Whether this caller may act on
this object is for the handler to decide, as in Otto's
[two-layer authorization](authentication.md): read the caller from
`env['otto.mcp.auth']` and check ownership before acting.

## Serve MCP 2026-07-28

`protocol_versions` selects the revisions an endpoint serves:

```ruby
otto.enable_mcp!(protocol_versions: '2026-07-28', authenticator: verifier)

# or both, while clients migrate
otto.enable_mcp!(protocol_versions: %w[2026-07-28 2024-11-05], auth_tokens: [ENV.fetch('MCP_TOKEN')])
```

Under `2026-07-28` there is no `initialize` request and no session. Every
request states its protocol version and the client's capabilities in
`params._meta`, and repeats the version, the method, and the tool name or
resource URI in HTTP headers:

```sh
curl -sS -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <access-token>' \
  -H 'MCP-Protocol-Version: 2026-07-28' \
  -H 'Mcp-Method: tools/call' \
  -H 'Mcp-Name: create_user' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
        "name":"create_user","arguments":{"name":"Ada"},
        "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
                 "io.modelcontextprotocol/clientCapabilities":{}}}}'
```

What Otto does for a request under this revision:

- **Methods.** `server/discover`, `tools/list`, `tools/call`, `resources/list`
  and `resources/read`. Any other method, including `initialize`, gets `404`
  and `-32601`.
- **Metadata.** A request without the `MCP-Protocol-Version` header gets
  `400` and `-32020`. A header that names a version the endpoint does not
  serve gets `400` and `-32022`, with the versions it does serve in
  `data.supported`, whatever else the request lacks. After that, an
  `Mcp-Method` or `Mcp-Name` header that is missing or differs from the body,
  or a header version that differs from the version in `_meta`, gets `400`
  and `-32020`, and a `_meta` that lacks the version or the client
  capabilities gets `400` and `-32602`. `Mcp-Name` is compared as bytes, and
  its Base64 form must be the canonical encoding.
- **Ids.** An error for a request whose `id` could be read returns it. An
  endpoint that serves only `2026-07-28` leaves `id` out of an error for a
  request whose `id` could not be read, since that revision has no null id.
- **Results.** Every result has `resultType` and names the server in
  `_meta`. Set the name and version with `server_info:`. `server/discover`
  also returns `instructions:` when that option is set.
- **Caching hints.** `server/discover` and the two lists return `ttlMs`
  (`cache_ttl_ms:`, default `0`) and `cacheScope`. The scope is `private`
  when any tool or resource requires a scope, since the list then depends on
  the caller. `resources/read` always returns `ttlMs: 0` and
  `cacheScope: "private"`.
- **Errors.** An unknown tool or an unknown resource is `-32602`, where
  `2024-11-05` uses `-32002` and `-32001`. A handler failure is `-32603` with
  the `error_id` of the log entry in `data.error_id`.
- **GET and DELETE** on the endpoint get `405`.
- **Origin.** A request with an `Origin` header gets `403` unless the origin
  is listed in `allowed_origins:`. See below.

On an endpoint that serves both revisions, a request whose `_meta` states a
protocol version is served under `2026-07-28`, and its headers must agree
with it. Without that, the `MCP-Protocol-Version` header decides: any version
other than `2024-11-05` selects `2026-07-28`. A request that declares
nothing, which is how a `2024-11-05` client sends every request, is served
under `2024-11-05`.

### Origin validation

The specification's
[transport security section](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/bd5bc16fb0b4eee9e0a1994ffaa1d67f213865ac/docs/specification/2026-07-28/basic/transports/streamable-http.mdx)
says: "If the `Origin` header is present and invalid, servers **MUST** respond
with HTTP 403 Forbidden."

Otto treats an origin as valid only when it appears in `allowed_origins:`.
Each entry is `scheme://host` with an optional port and nothing after it, and
the comparison ignores case. The default list is empty, so a browser page
cannot call the endpoint until its origin is listed. A request with no
`Origin` header, which is what a non-browser client sends, is not affected.

Otto does not compare `Origin` with the request's `Host`. A page that has
rebound its hostname to the server's address sends an `Origin` that matches
`Host`, so that comparison would admit it.

The check runs on every request to an endpoint that serves `2026-07-28`,
whichever revision the request uses. An endpoint that serves only `2024-11-05`
runs it when `allowed_origins:` is set and otherwise checks no origin, as
before.

`allowed_origins:` decides which origins are refused. It does not make the
endpoint usable from a browser page by itself: Otto's MCP endpoint sends no
CORS response headers and does not answer preflight `OPTIONS` requests. Add
those in the application if a browser client needs them.

### Not implemented

Otto answers every request with a single JSON object. It does not implement
prompts, `subscriptions/listen`, streamed (SSE) responses, pagination cursors,
client-to-server notifications, sampling, roots, MCP logging, form-mode
elicitation or `x-mcp-header`. It declares no `listChanged` capability. A
`cursor` on a list request gets `-32602`, because Otto never issues one.

## Hosted endpoints

`hosted: true` is for an endpoint that people outside your organization
connect their own MCP clients to. It makes the application refuse to boot
unless the endpoint has everything in the table below.

```ruby
otto = Otto.new
otto.enable_mcp!(
  hosted: true,
  http_endpoint: '/mcp',
  authenticator: verifier,
  resource_uri: 'https://mcp.example.com/mcp',
  authorization_servers: ['https://auth.example.com'],
  scopes_supported: ['handoff:read'],
  allowed_origins: [],
  request_state_secret: ENV.fetch('MCP_REQUEST_STATE_SECRET'),
  server_info: { name: 'Example', version: '1.4.0' },
)
```

| Requirement | Reason |
| --- | --- |
| `authenticator:` | Every request has a verified caller. `auth_tokens:` and `allow_unauthenticated: true` are refused. |
| `resource_uri:` and `authorization_servers:` | A token must have been issued for this endpoint, and a client must be able to find where to get one. |
| `2026-07-28` only | `protocol_versions` defaults to it, and a list that includes `2024-11-05` is refused. |
| Every tool states `output_schema:` and `scopes:` | Nothing a tool returns is unchecked, and no tool is open to every caller by omission. `scopes: []` states that any authenticated caller may use the tool. |
| Every resource states `scopes:` | As for tools. |
| No `MCP` or `TOOL` route lines | A route line has no place for schemas or scopes. Loading one raises `Otto::RouteDefinitionError`. Use `register_mcp_tool` and `register_mcp_resource`. |
| Enabled before anything is registered | `enable_mcp!(hosted: true)` raises if a tool or resource is already registered, for example from a routes file loaded with `mcp_http: false`. |

`output_schema: nil` and `scopes: nil` count as not stated. The registry of a
hosted endpoint applies the same rules to anything handed to it directly.

### Tokens issued for this endpoint

The specification's
[token handling section](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/bd5bc16fb0b4eee9e0a1994ffaa1d67f213865ac/docs/specification/2026-07-28/basic/authorization/index.mdx)
says: "MCP servers **MUST** validate that access tokens were issued
specifically for them as the intended audience".

When `resource_uri:` is set, Otto refuses any `Context` whose `audience` does
not include that URI, compared as an exact string, and logs
`MCP token not issued for this endpoint`. The authenticator must therefore
report the audience it verified. A token your authorization server issued for
another API is refused even though the authenticator accepted it.

Otto does not verify tokens. Signature, expiry, issuer and revocation are the
authenticator's work, and Otto calls it on every request, so a revoked token
stops working as soon as the authenticator says so.

### Protected resource metadata

With `resource_uri:` and `authorization_servers:` set, Otto builds the OAuth
protected resource metadata document (RFC 9728) that tells a client which
authorization servers issue tokens for the endpoint:

```json
{"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com"],"scopes_supported":["handoff:read"],"bearer_methods_supported":["header"]}
```

A `401` or `403` challenge names the document's URL, which is the well-known
path inserted before the path of `resource_uri`:
`https://mcp.example.com/.well-known/oauth-protected-resource/mcp`.

Otto serves the document, without authentication, at
`/.well-known/oauth-protected-resource` followed by the endpoint path. That is
the URL above when the application is mounted at the root of its origin and
the endpoint path equals the path of `resource_uri`. An application mounted
under a path prefix cannot serve a path at the root. Serve the document from
the application that owns the root, using
`otto.mcp_server.protected_resource_metadata`, which returns it as a frozen
Hash.

### What remains the application's work

- Verifying tokens, as described above.
- Deciding whether this caller may act on this object. Scopes do not express
  ownership.
- The page behind a URL input request, including the check that the person
  who opened it is the caller it was issued to.
- Keeping secrets and handles that grant access out of tool results. An output
  schema with `additionalProperties: false` turns a handler that returns more
  than intended into an error instead of a disclosure, but only for the
  fields the schema describes.
- An audit record of who called what. Otto logs refusals and failures, not
  successful calls.

## Ask the person for input through a page

A tool that needs something sensitive from the person at the MCP client, such
as a secret to hand off, should not take it as an argument. Arguments pass
through the client and the model. The specification's
[elicitation page](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/bd5bc16fb0b4eee9e0a1994ffaa1d67f213865ac/docs/specification/2026-07-28/client/elicitation.mdx)
says: "Servers **MUST NOT** use form mode elicitation to request sensitive
information such as passwords, API keys, access tokens, or payment
credentials".

Instead, the handler returns `Otto::MCP::InputRequired.url`. Otto answers the
call with a request for the client to open a page, and the client retries the
call when the person has responded.

```ruby
otto.register_mcp_tool('arrange_secret_delivery',
  description: 'Hand a secret to a recipient without showing it to the assistant.',
  input_schema: { type: 'object', properties: { recipient: { type: 'string' } }, required: ['recipient'] },
  output_schema: {
    type: 'object',
    properties: { operation_id: { type: 'string' }, state: { enum: %w[awaiting_input queued] } },
    required: %w[operation_id state],
    additionalProperties: false,
  },
  scopes: ['handoff:write'],
) do |arguments, env|
  call = env['otto.mcp.call']

  if call.retry?
    operation = Handoffs.find(call.state.fetch('operation_id'), owner: call.auth.subject)
    next { operation_id: operation.id, state: operation.state }
  end

  raise Otto::MCP::ToolError, 'Open your requests inbox to continue.' unless call.url_elicitation?

  operation = Handoffs.open(owner: call.auth.subject, recipient: arguments.fetch('recipient'))
  Otto::MCP::InputRequired.url('handoff',
    url: "https://example.com/handoffs/#{operation.id}",
    message: 'Enter the secret on example.com.',
    state: { 'operation_id' => operation.id },
  )
end
```

`env['otto.mcp.call']` is an `Otto::MCP::Call`:

| Member | Meaning | Source |
| --- | --- | --- |
| `auth` | The caller, as in `env['otto.mcp.auth']` | Verified by the authenticator |
| `state` | The `state:` of the input request this call retries, or `nil` | Verified by Otto |
| `retry?` | Whether `state` is present | Verified by Otto |
| `url_elicitation?` | Whether the client says it can open a URL | Sent by the client |
| `input_action(key)` | `"accept"`, `"decline"` or `"cancel"` for the request with that key | Sent by the client |
| `client_capabilities`, `client_info`, `protocol_version` | What the request declared | Sent by the client |

What Otto does with an input request:

- **It needs a verified caller.** The specification says: "Servers **MUST**
  bind elicitation requests to the client and user identity". On an endpoint
  with no authenticator there is no identity, so Otto does not send the
  request. The call fails with a JSON-RPC internal error and the log code
  `input_request_unbound`.
- **It needs a client that can open a URL.** When the client did not declare
  `elicitation.url` in its capabilities, Otto answers `400` and `-32021` with
  the missing capability in `data.requiredCapabilities`, and does not send the
  URL. Check `call.url_elicitation?` first to offer another route, as the
  example does.
- **It seals the state.** Otto encrypts `state:` with AES-256-GCM and sends it
  as `requestState`. The client returns it unchanged on the retry. Otto opens
  it only for the same issuer, subject, client ID and tenant, calling the
  same tool with the same arguments at the same endpoint path and resource
  URI, within `ttl:` seconds (default 900, at most 86400). Otherwise the
  retry gets `400` and `-32602`, and the handler does not run.
- **It limits the state's size.** `state:` is at most 8192 bytes of JSON.
  Keep the record in your own store and put its identifier in the state.
- **It does not make the state single-use.** A state can be presented again
  until it expires. The specification says: "Servers for which a given
  `requestState` must be consumed at most once (e.g., one-time redemptions)
  **MUST** enforce that invariant server-side." Keep that invariant in the
  operation record, as the example does by looking the operation up.

Set `request_state_secret:` to a stable value of at least 32 bytes when the
application runs as more than one process. Without it, each process generates
its own key and refuses states the others issued. Otto logs a warning the
first time a process issues a state under a generated key. Give each endpoint
its own secret: two endpoints with the same secret, endpoint path and
resource URI are one endpoint as far as a state is concerned.

Only a tool can ask for input. A resource handler that returns an input
request fails the read with a JSON-RPC internal error.

`call.retry?` is the way to tell a retry from a first call. `inputResponses`
alone proves nothing, because any client can send it. And the specification
says of a URL request that `"accept"` "indicates that the user has consented
to the interaction. It does not mean that the interaction is complete." Only
the application that serves the page knows whether the person finished, so
the example reads the operation's state from its own record.

The page is the application's. The specification places these requirements on
the server that issues the URL:

- "**MUST NOT** include sensitive information about the end-user, including
  credentials, personally identifiable information, etc., in the URL sent to
  the client in a URL elicitation request."
- "**MUST NOT** provide a URL which is pre-authenticated to access a protected
  resource, as the URL could be used to impersonate the user by a malicious
  client."
- "The MCP Server **MUST** verify the identity of the user who opens the URL
  before accepting information."

So the URL may locate a pending operation, and the page must still establish,
from its own browser session, that the person who opened it is the subject
the operation belongs to. A person other than the caller cannot be reached
this way: the client opens the URL for whoever is using it.

Under `2024-11-05` there is no way to ask for input in the middle of a call.
A tool that returns an input request there produces a result with
`isError: true` and the text
`This tool needs a client that supports MCP 2026-07-28.`

## Configuration reference

`enable_mcp!` accepts the canonical option names below and the listed `mcp_`
aliases. `Otto.new` accepts both for the options down to
`allow_unauthenticated`, and only the `mcp_` spelling for the options from
`protocol_versions` down: the hash given to `Otto.new` also configures the
rest of Otto and may contain an application's own options, so a bare
`hosted:` or `instructions:` there is not read as MCP's. Keys may be Symbols
or Strings. Providing two spellings of one option with different values
raises `ArgumentError`.

| Option | Alias | Default | Effect |
| --- | --- | --- | --- |
| `http_endpoint` | `mcp_endpoint` | `'/_mcp'` | Slash-prefixed literal endpoint path, without `:name` segments or `*`. |
| `auth_tokens` | `mcp_auth_tokens` | `[]` | String or array of bearer tokens. |
| `enable_validation` | `mcp_validation` | `true` | Validates the JSON-RPC request envelope. |
| `enable_rate_limiting` | `mcp_rate_limiting` | `true` | Enables MCP rate-limit configuration. |
| `requests_per_minute` | `mcp_requests_per_minute` | `60` | Per-client-IP limit for all MCP endpoint requests. |
| `tools_per_minute` | `tool_calls_per_minute`, `mcp_tool_calls_per_minute` | `20` | Additional per-client-IP limit for `tools/call`. |
| `allow_unauthenticated` | `mcp_allow_unauthenticated` | `false` | Acknowledges an intentionally open endpoint. |
| `protocol_versions` | `mcp_protocol_versions` | `'2024-11-05'`; `'2026-07-28'` when hosted | String or array of the revisions to serve. |
| `authenticator` | `mcp_authenticator` | none | Object that responds to `call(token, env)`. |
| `hosted` | `mcp_hosted` | `false` | Requires the settings in [Hosted endpoints](#hosted-endpoints). |
| `resource_uri` | `mcp_resource_uri` | none | Canonical URI of the endpoint. Needs `authenticator` and `authorization_servers`. |
| `authorization_servers` | `mcp_authorization_servers` | none | Array of authorization server URLs. Needs `resource_uri`. |
| `scopes_supported` | `mcp_scopes_supported` | none | Scopes named in the `401` challenge and the metadata document. Needs `authenticator`. |
| `allowed_origins` | `mcp_allowed_origins` | none | Array of origins a browser may call from. `[]` admits none. |
| `request_state_secret` | `mcp_request_state_secret` | generated per process | String of at least 32 bytes. |
| `server_info` | `mcp_server_info` | Otto's name and version | Hash with `name` and `version`, and optionally `title`. |
| `instructions` | `mcp_instructions` | none | Guidance for the model, returned by `server/discover`. |
| `cache_ttl_ms` | `mcp_cache_ttl_ms` | `0` | `ttlMs` of `server/discover` and list results. |

Limits must be positive integers. Endpoint paths must be strings beginning with
`/`; tokens must be non-blank strings; and all flags must be exactly `true` or
`false`. Invalid values fail at boot with `ArgumentError`. So does a `nil` for
any option from `protocol_versions` down: omit the option to leave it unset.

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
2. Origin validation, when the endpoint checks origins
3. Authentication
4. JSON-schema validation

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
Tools, resources, authenticators and tokens are never shared: each request is
dispatched to the MCP server of the Otto application that routed it.

If general Otto rate limiting is also enabled, its `Rack::Attack` responder
replaces MCP's JSON-RPC-specific `429` response. Do not rely on the MCP error
body in that combined configuration.

## Errors and limits

Responses that are the same under both revisions:

| Situation | HTTP status and JSON-RPC code |
| --- | --- |
| Missing or invalid static token | `401`, `-32000` (`Unauthorized`) |
| Missing or invalid token, with an authenticator | `401`, `401` (`Unauthorized`), and a `WWW-Authenticate` challenge |
| Caller lacks a scope the tool or resource requires | `403`, `403` (`Forbidden`), and an `insufficient_scope` challenge |
| `Origin` not allowed | `403`, `403` (`Forbidden`) |
| Invalid JSON, a body that is not UTF-8 or has a number that is not finite, an invalid request envelope, HTTP method, or content type | `400`, `-32700` or `-32600` |
| Invalid method parameters | `400`, `-32602` |
| `params` that is not an object | `400`, `-32600` with `enable_validation`, otherwise `-32602` |
| The authenticator raises | `500`, from Otto's error handling, as `Otto::MCP::AuthenticatorError` |
| Invalid arguments for a declared tool, or `Otto::MCP::ToolError` | `200`, a tool result with `isError: true` |
| Resource or tool handler raises, or a result fails its output schema | `500`, `-32603`; details are logged, not returned to the client |
| MCP rate limit exceeded | `429`, `-32000` unless general Otto rate limiting overrides the response body |

Responses that differ:

| Situation | `2024-11-05` | `2026-07-28` |
| --- | --- | --- |
| Unknown protocol method | `400`, `-32601` | `404`, `-32601` |
| Unknown tool | `404`, `-32002` | `400`, `-32602` |
| Unknown resource | `404`, `-32001` | `400`, `-32602` |
| Header missing or different from the body | not checked | `400`, `-32020` |
| Client lacks a capability the call needs | not applicable | `400`, `-32021` |
| Protocol version not served | not checked | `400`, `-32022` |
| `requestState` not issued for this caller and call | not applicable | `400`, `-32602` |
| `GET` or `DELETE`, on an endpoint that serves the revision | `404` | `405` |

The JSON-RPC codes `401` and `403` are Otto's own. They mirror the HTTP status
and are outside the range JSON-RPC reserves, which is where the
[specification's error code policy](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/bd5bc16fb0b4eee9e0a1994ffaa1d67f213865ac/docs/specification/2026-07-28/basic/index.mdx)
asks for new codes: "New error codes for purposes not defined by this
specification **SHOULD** be allocated outside the JSON-RPC reserved range
(`-32768` to `-32000`)". A client acts on the HTTP status and the
`WWW-Authenticate` header. The static-token `401` and the rate limiter's `429`
predate that policy and keep `-32000`.

Otto provides HTTP transport only. It does not implement an stdio transport.
See [Not implemented](#not-implemented) for the parts of `2026-07-28` it
leaves out.

## Specification sources

Statements in this guide about what MCP requires quote revision `2026-07-28`
of the specification as published in the
[modelcontextprotocol repository](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/bd5bc16fb0b4eee9e0a1994ffaa1d67f213865ac/docs/specification/2026-07-28)
at commit `bd5bc16`. The specification names its
[TypeScript schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/bd5bc16fb0b4eee9e0a1994ffaa1d67f213865ac/schema/2026-07-28/schema.ts)
as the source of truth for protocol messages. Everything else in this guide
describes what Otto does.
