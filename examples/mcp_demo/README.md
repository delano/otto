# Otto MCP Demo

This example boots Otto's Model Context Protocol (MCP) JSON-RPC 2.0 endpoint at
`/_mcp`. Use it to verify endpoint initialization alongside ordinary Otto web
routes.

## What You'll Learn

- How to enable an MCP HTTP endpoint
- How the endpoint coexists with ordinary Otto web routes
- How to send a JSON-RPC 2.0 `initialize` request
- The current resource, tool, and authentication limitations described below

## Features Demonstrated

- **MCP endpoint**: A single `POST /_mcp` endpoint
- **Web interface**: Separate web routes coexist with the MCP endpoint
- **JSON-RPC 2.0**: `initialize`, `resources/list`, and `tools/list` requests

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
`Rack::Attack` before Otto in `config.ru`, as this example does.

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

## Current Limitations

The `auth_tokens`, `requests_per_minute`, and `tools_per_minute` values shown in
`config.ru` are not forwarded to the MCP server by the current configuration
path. Consequently, this example's endpoint does not require either displayed
bearer token and its configured rate-limit values are not applied.

Likewise, although `routes` contains `MCP /users` and `TOOL /create_user`
declarations, the current route-loading path does not register them. Therefore
`resources/list` and `tools/list` both return empty arrays, and `resources/read`
or `tools/call` for those names fails. This README documents the runnable
endpoint behavior; do not use this example as a resource or tool integration
template until those routes are registered.

## Interacting with the MCP Endpoint

All MCP interactions use the `POST /_mcp` endpoint. Each request is a JSON-RPC 2.0 request with:

- `jsonrpc`: Always `"2.0"`
- `method`: The RPC method name
- `id`: Request ID (for matching responses)
- `params`: Optional parameters as an object

Required header:
- `Content-Type: application/json`

`Authorization: Bearer <token>` is accepted but not enforced by the current example configuration.

Example:
```sh
curl -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "method": "initialize",
    "id": 1,
    "params": {}
  }'
```

### MCP: Initialize

The `initialize` method is a built-in MCP method that returns information about the available resources and tools.

```sh
curl -X POST http://localhost:9292/_mcp \
     -H 'Content-Type: application/json' \
     -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}'
```

## Verification

A successful `initialize` request returns `result.protocolVersion`,
`result.capabilities`, and `result.serverInfo` with the same request ID. To
confirm the current registry state, run:

```sh
curl -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"resources/list","id":2}'

curl -X POST http://localhost:9292/_mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":3}'
```

Each request returns `"jsonrpc":"2.0"` and an empty `resources` or `tools`
array in the current checkout.

## File Structure

- `README.md`: This file
- `app.rb`: Application logic
  - `DemoApp`: Web interface and health check
  - `UserAPI`: Intended MCP resource and tool handlers (not registered by the current route-loading path)
- `config.ru`: Rack configuration (loads Otto, enables MCP)
- `routes`: Route definitions for web and MCP routes

## Routes

The ordinary web routes in `routes` are active:

```
GET  /        DemoApp.index
GET  /health  DemoApp.health
```

The file also contains `MCP /users UserAPI.mcp_list_users` and
`TOOL /create_user UserAPI.mcp_create_user`. See [Current Limitations](#current-limitations):
they are not registered by this checkout's route-loading path.

## Next Steps

- Build a CLI that communicates with the MCP endpoint
- Integrate with AI systems that support MCP
- Combine with [Authentication](../authentication_strategies/) for role-based MCP access
- Explore [Advanced Routes](../advanced_routes/) for more routing patterns
