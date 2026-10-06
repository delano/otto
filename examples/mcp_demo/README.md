# Otto MCP Demo

This example boots Otto's Model Context Protocol (MCP) JSON-RPC 2.0 endpoint at
`/_mcp`, with one resource and one tool declared in the routes file, alongside
ordinary Otto web routes.

## What You'll Learn

- How to enable an MCP HTTP endpoint
- How to declare an MCP resource and tool in the routes file
- How the endpoint coexists with ordinary Otto web routes
- How to send JSON-RPC 2.0 requests to list, read, and call them
- How bearer-token authentication protects the endpoint

## Features Demonstrated

- **MCP endpoint**: A single `POST /_mcp` endpoint
- **Resource and tool**: The `users` resource and the `create_user` tool
- **Web interface**: Separate web routes coexist with the MCP endpoint
- **JSON-RPC 2.0**: `initialize`, `resources/list`, `resources/read`,
  `tools/list`, and `tools/call` requests

## How to Run

Run this example from an Otto source checkout. It requires Ruby 3.2 through
4.0, Bundler, and the development dependencies: `rackup` is a development
dependency in the root `Gemfile` and is not installed with the released `otto`
gem. MCP enables schema validation and rate limiting by default. Those features
require `json_schemer` 2.0.0 or newer in the 2.x series and `rack-attack` 6.7.0
or newer in the 6.x series:

```ruby
# Gemfile
gem 'json_schemer', '~> 2.0'
gem 'rack-attack', '~> 6.7'
```

If either enabled feature's gem is missing or incompatible, MCP setup raises
`Otto::OptionalDependencyError` during configuration. Pass
`enable_validation: false` or `enable_rate_limiting: false` to `enable_mcp!`, or
alongside `mcp_enabled: true` in the `Otto.new` options, only when that protection
is intentionally disabled. To enforce the configured limits, mount
`Rack::Attack` before Otto in `config.ru`, as this example does. `Rack::Attack`
counts requests in a cache store and has no default store outside Rails, so
`config.ru` sets a small in-process store (`DemoRateLimitStore`). Use a shared
store, such as Redis, when the app runs in more than one process.

```sh
cd /path/to/otto
bundle config set with development
bundle install
cd examples/mcp_demo
bundle exec rackup config.ru
```


The server listens at `http://localhost:9292` by default.

- **Web interface**: Open `http://localhost:9292/`.
- **Health check**: `curl -i http://localhost:9292/health` returns `200` and `OK`.
- **MCP endpoint**: Send JSON-RPC 2.0 requests to `http://localhost:9292/_mcp`.

## Authentication

`config.ru` configures two bearer tokens, and Otto enforces them: every request
to `/_mcp` must send `Authorization: Bearer demo-token-123` (or
`X-MCP-Token: demo-token-123`). Requests without a valid token get HTTP `401`
and a JSON-RPC `Unauthorized` error. The `requests_per_minute` and
`tools_per_minute` values in `config.ru` are applied as configured. See the
[MCP guide](../../docs/guides/mcp.md) for the full option list.

## Resources and Tools

`routes` declares one resource and one tool:

```
GET   /mcp/users        MCP users UserAPI.mcp_list_users
POST  /mcp/create_user  TOOL create_user UserAPI.mcp_create_user
```

The verb and path are required by the route-file grammar but create no HTTP
route: the resource and the tool are served only through `POST /_mcp`. The word
after `MCP` is the resource URI (`users`), and the word after `TOOL` is the tool
name (`create_user`). MCP must be enabled when the routes file loads, as
`Otto.new('routes', mcp_enabled: true, ...)` in `config.ru` does. If the file
loads before MCP is enabled, Otto skips its `MCP` and `TOOL` lines.

`UserAPI.mcp_list_users` takes no arguments. A resource handler may instead
take one argument, the Rack env of the MCP request. `UserAPI.mcp_create_user`
receives the tool `arguments` and the Rack env. `MCP` and `TOOL` lines cannot
use `auth=`, `role=`, or `csrf=`; see the
[MCP guide](../../docs/guides/mcp.md#register-resources-and-tools).

## Interacting with the MCP Endpoint

All MCP interactions use the `POST /_mcp` endpoint. Each request is a JSON-RPC 2.0 request with:

- `jsonrpc`: Always `"2.0"`
- `method`: The RPC method name
- `id`: Request ID (for matching responses)
- `params`: Optional parameters as an object

Required headers:
- `Content-Type: application/json`
- `Authorization: Bearer demo-token-123` (or `X-MCP-Token: demo-token-123`)

Example:
```sh
curl -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer demo-token-123' \
  -d '{
    "jsonrpc": "2.0",
    "method": "initialize",
    "id": 1,
    "params": {}
  }'
```

### MCP: Initialize

The `initialize` method is a built-in MCP method that returns the protocol
version, the server capabilities, and the server name and version.

```sh
curl -X POST http://localhost:9292/_mcp \
     -H 'Content-Type: application/json' \
     -H 'Authorization: Bearer demo-token-123' \
     -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}'
```

## Verification

A successful `initialize` request returns `result.protocolVersion`,
`result.capabilities`, and `result.serverInfo` with the same request ID. To
list the registered resource and tool, run:

```sh
curl -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer demo-token-123' \
  -d '{"jsonrpc":"2.0","method":"resources/list","id":2}'

curl -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer demo-token-123' \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":3}'
```

`resources/list` returns one entry with `"uri":"users"`, and `tools/list`
returns one entry with `"name":"create_user"`. Read the resource and call the
tool:

```sh
curl -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer demo-token-123' \
  -d '{"jsonrpc":"2.0","method":"resources/read","id":4,"params":{"uri":"users"}}'

curl -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer demo-token-123' \
  -d '{"jsonrpc":"2.0","method":"tools/call","id":5,"params":{"name":"create_user","arguments":{"name":"Carol"}}}'
```

`resources/read` returns `result.contents[0].text`, the JSON list of users
from `UserAPI.mcp_list_users`. `tools/call` returns `result.content[0].text`,
starting with `Created user:`. `tools_per_minute: 20` limits each client IP:
the 21st `tools/call` in the same 60-second window gets HTTP `429`.

## File Structure

- `README.md`: This file
- `app.rb`: Application logic
  - `DemoApp`: Web interface and health check
  - `UserAPI`: MCP resource and tool handlers
- `config.ru`: Rack configuration (loads Otto, enables MCP, sets the
  `Rack::Attack` store)
- `routes`: Route definitions for web and MCP routes

## Routes

```
GET   /                 DemoApp.index
GET   /health           DemoApp.health
GET   /mcp/users        MCP users UserAPI.mcp_list_users
POST  /mcp/create_user  TOOL create_user UserAPI.mcp_create_user
```

The first two are ordinary web routes. The last two register the MCP resource
and tool described in [Resources and Tools](#resources-and-tools).

## Next Steps

- Build a CLI that communicates with the MCP endpoint
- Integrate with AI systems that support MCP
- Protect the endpoint with `mcp_auth_tokens`. `MCP` and `TOOL` routes cannot use
  `auth=`, `role=`, or `csrf=`; see the [MCP guide](../../docs/guides/mcp.md#register-resources-and-tools)
- Explore [Advanced Routes](../advanced_routes/) for more routing patterns
