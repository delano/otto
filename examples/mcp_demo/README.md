# Otto MCP Demo

This example demonstrates Otto's Model-Controller-Protocol (MCP) feature. MCP provides a standardized JSON-RPC 2.0 endpoint (`/_mcp`) for programmatic access to your application resources and tools.

MCP is useful for building CLIs, admin interfaces, integrating with AI systems, or allowing other services to interact with your application.

## What You'll Learn

- How to set up an MCP endpoint for programmatic access
- Exposing application resources via JSON-RPC 2.0
- Securing MCP endpoints with bearer token authentication
- Distinguishing between read-only resources and executable tools
- Organizing methods for both web and MCP interfaces
- How MCP integrates with your existing Otto application

## Features Demonstrated

- **MCP Endpoint**: Single `POST /_mcp` endpoint for all interactions
- **Authentication**: Bearer token authentication for secure access
- **Rate Limiting**: Built-in rate limiting to prevent abuse
- **Resources**: Read-only data exposed via `MCP` routes
- **Tools**: Executable actions exposed via `TOOL` routes
- **Web Interface**: Separate web routes coexist with MCP routes
- **JSON-RPC 2.0**: Standard protocol for all MCP interactions

## How to Run

### Using rackup (recommended)

```sh
cd examples/mcp_demo
rackup config.ru
```

### Using thin

```sh
cd examples/mcp_demo
thin -R config.ru -p 9292 start
```

The server will start on `http://localhost:9292`.

- **Web interface**: Navigate to `http://localhost:9292` in your browser
- **MCP endpoint**: Send JSON-RPC 2.0 requests to `http://localhost:9292/_mcp`

## Authentication

All MCP requests require bearer token authentication via the `Authorization` header.

Valid tokens:
- `demo-token-123` - Standard user
- `another-token-456` - Alternative user

## Interacting with the MCP Endpoint

All MCP interactions use the `POST /_mcp` endpoint. Each request is a JSON-RPC 2.0 request with:

- `jsonrpc`: Always `"2.0"`
- `method`: The RPC method name (derived from route path)
- `id`: Request ID (for matching responses)
- `params`: Optional parameters as an object

Required headers:
- `Authorization: Bearer <token>`
- `Content-Type: application/json`

Example:
```sh
curl -X POST http://localhost:9292/_mcp \
  -H 'Authorization: Bearer demo-token-123' \
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
     -H 'Authorization: Bearer demo-token-123' \
     -H 'Content-Type: application/json' \
     -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}'
```

### Resource: List Users

This calls the `UserAPI.mcp_list_users` method defined as an `MCP` route. The method name for the JSON-RPC call is derived from the route path (`/users` -> `users/list`).

```sh
curl -X POST http://localhost:9292/_mcp \
     -H 'Authorization: Bearer demo-token-123' \
     -H 'Content-Type: application/json' \
     -d '{"jsonrpc":"2.0","method":"users/list","id":2}'
```

### Tool: Create User

This calls the `UserAPI.mcp_create_user` method defined as a `TOOL` route. The method name is derived from the route path (`/create_user` -> `create_user`).

```sh
curl -X POST http://localhost:9292/_mcp \
     -H 'Authorization: Bearer demo-token-123' \
     -H 'Content-Type: application/json' \
     -d '{
          "jsonrpc": "2.0",
          "method": "create_user",
          "id": 3,
          "params": {
            "name": "Charlie",
            "email": "charlie@example.com"
          }
        }'
```

## Expected Output

### Successful Initialize Request
```json
{
  "jsonrpc": "2.0",
  "result": {
    "resources": [
      {
        "uri": "users",
        "name": "User List",
        "description": "List all users"
      }
    ],
    "tools": [
      {
        "name": "create_user",
        "description": "Create a new user",
        "inputSchema": {
          "type": "object",
          "properties": {
            "name": { "type": "string" },
            "email": { "type": "string" }
          }
        }
      }
    ]
  },
  "id": 1
}
```

### Successful Resource Request
```json
{
  "jsonrpc": "2.0",
  "result": {
    "users": [
      { "id": 1, "name": "Alice", "email": "alice@example.com" },
      { "id": 2, "name": "Bob", "email": "bob@example.com" }
    ]
  },
  "id": 2
}
```

### Successful Tool Execution
```json
{
  "jsonrpc": "2.0",
  "result": {
    "user": {
      "id": 3,
      "name": "Charlie",
      "email": "charlie@example.com"
    }
  },
  "id": 3
}
```

### Authentication Failure
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32003,
    "message": "Unauthorized"
  },
  "id": 1
}
```

## File Structure

- `README.md`: This file
- `app.rb`: Application logic
  - `DemoApp`: Web interface with HTML pages
  - `UserAPI`: MCP handlers for resources and tools
- `config.ru`: Rack configuration (loads Otto, enables MCP)
- `routes`: Route definitions for web and MCP routes

## Route Types

### Web Routes
Regular HTTP routes for the web interface:
```
GET  /            DemoApp#welcome
GET  /users       DemoApp#list_users
```

### MCP Resource Routes
Read-only resources exposed via MCP:
```
MCP  /users       UserAPI#mcp_list_users
```
- Called via: `POST /_mcp` with method `users/list`

### MCP Tool Routes
Executable operations exposed via MCP:
```
TOOL /create_user UserAPI#mcp_create_user
```
- Called via: `POST /_mcp` with method `create_user`

## Understanding MCP Method Names

MCP route paths are converted to method names:

| Route Type | Path | Method Name | Handler |
|-----------|------|-------------|---------|
| MCP | `/users` | `users/list` | `mcp_list_users` |
| MCP | `/users/:id` | `users/get` | `mcp_get_user` |
| TOOL | `/create_user` | `create_user` | `mcp_create_user` |
| TOOL | `/users/:id/update` | `users/update` | `mcp_update_user` |

## Next Steps

- Build a CLI that communicates with the MCP endpoint
- Integrate with AI systems that support MCP
- Combine with [Authentication](../authentication_strategies/) for role-based MCP access
- Explore [Advanced Routes](../advanced_routes/) for more routing patterns

## Further Reading

- [Architecture Guide](../../docs/architecture.md) - How routing works
- [Best Practices](../../docs/best-practices.md) - MCP patterns and security
- [Troubleshooting](../../docs/troubleshooting.md) - Common MCP issues
- [CLAUDE.md](../../CLAUDE.md#mcp) - Detailed MCP documentation (if available)
