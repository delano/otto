# Otto MCP Demo

This example demonstrates Otto's Model-Controller-Protocol (MCP) feature. MCP provides a standardized JSON-RPC 2.0 endpoint (`/_mcp`) that allows you to expose application resources and tools securely.

This is useful for building CLIs, admin interfaces, or allowing other services to interact with your application programmatically.

## Features Demonstrated

*   **MCP Endpoint:** A single `POST /_mcp` endpoint for all API interactions.
*   **Authentication:** Requests to the MCP endpoint are protected by bearer token authentication.
*   **Rate Limiting:** The endpoint has its own rate limiting to prevent abuse.
*   **Resources:** Read-only data exposed via `MCP` routes (e.g., listing users).
*   **Tools:** Actions or operations exposed via `TOOL` routes (e.g., creating a user).

## How to Run

1.  Make sure you have `bundler` and `thin` installed:
    ```sh
    gem install bundler thin
    ```

2.  Install the dependencies from the root of the project:
    ```sh
    bundle install
    ```

3.  Start the server from this directory (`examples/mcp_demo`):
    ```sh
    thin -R config.ru -p 9292 start
    ```
    *Note: This demo uses port 9292 as is conventional for Rack apps.*

4.  Open your browser and navigate to `http://localhost:9292` to see the welcome page.

## Interacting with the MCP Endpoint

All interactions happen via `POST` requests to `http://localhost:9292/_mcp`. You must provide an `Authorization: Bearer <token>` header and a `Content-Type: application/json` header.

Valid tokens are `demo-token-123` and `another-token-456`.

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

## File Structure

*   `README.md`: This file.
*   `app.rb`: Contains the application logic, including the `DemoApp` for web pages and the `UserAPI` for MCP handlers.
*   `config.ru`: The Rack configuration file. It loads the Otto framework, enables MCP, and runs the application.
*   `routes`: Defines the standard web routes as well as the `MCP` and `TOOL` routes for the MCP endpoint.
