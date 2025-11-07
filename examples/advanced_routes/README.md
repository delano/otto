# Otto - Advanced Routes Example

This example demonstrates advanced routing features in Otto, including response type negotiation, CSRF exemptions, logic classes, and namespaced routing.

## What You'll Learn

- How to define response types (JSON, view, redirect) in routes
- Using logic classes to encapsulate business logic
- CSRF exemption for APIs and webhooks
- Routing to namespaced classes with complex hierarchies
- Custom route parameters for flexible routing
- How Otto handles multiple controllers and modules

## Project Structure

The example is organized to separate concerns:

- `config.ru`: Rack configuration that loads and runs the Otto application
- `routes`: Comprehensive reference for advanced routing syntax
- `app.rb`: Loader that requires all controller and logic files
- `app/controllers/`: Handler classes (`RoutesApp`, namespaced controllers)
- `app/logic/`: Business logic classes (simple, nested, namespaced)
- `run.rb`, `puma.rb`, `test.rb`: Alternative server/test runners

## Key Features Demonstrated

### Response Types
Define how responses are formatted directly in routes:
```
GET  /api/users        UserController#list      response=json
GET  /page             PageController#show      response=view
GET  /old-url          PageController#new-url   response=redirect
```

### Logic Classes
Route to specialized classes that encapsulate business logic:
```
GET  /calculate        DataProcessor   # Otto auto-instantiates and calls #process
GET  /report           ReportGenerator # Same pattern
```

### CSRF Exemption
Mark routes that don't need CSRF tokens (APIs, webhooks):
```
POST /api/webhook      WebhookHandler#receive   csrf=exempt
```

### Namespaced Routing
Handle complex class hierarchies naturally:
```
GET  /v2/dashboard     V2::Logic::Dashboard
GET  /admin/panel      Admin::Panel#dashboard
```

### Custom Parameters
Add arbitrary key-value pairs for flexible routing:
```
GET  /admin            AdminPanel#dashboard     role=admin
```

## How to Run

### Using rackup (recommended)

```sh
cd examples/advanced_routes
rackup config.ru
```

### Using alternative runners

```sh
ruby run.rb   # Basic rackup
ruby puma.rb  # Using puma server
ruby test.rb  # For testing
```

The application will be running at `http://localhost:9292`.

## Testing Routes

Use curl to test the different routes:

```sh
# JSON response
curl http://localhost:9292/json/test

# View response
curl http://localhost:9292/view/test

# Logic class routing
curl http://localhost:9292/logic/simple

# Namespaced routing
curl http://localhost:9292/logic/v2/dashboard

# Custom parameters
curl "http://localhost:9292/custom?role=admin"
```

## Expected Output

```
Listening on 127.0.0.1:9292, CTRL+C to stop

[JSON response]
GET /json/test 200 OK
Content-Type: application/json
{"status": "success", "data": {...}}

[Logic class routing]
GET /logic/simple 200 OK
{"processed": true, "input": "test"}

[Namespaced routing]
GET /logic/v2/dashboard 200 OK
{"version": "2.0", "dashboard": {...}}
```

## File Structure Details

### Routes File
The `routes` file is extensively commented to explain each feature:
- Response type specification
- CSRF exemption for APIs
- Logic class routing syntax
- Namespaced class resolution
- Custom parameter examples

### Controllers (`app/controllers/`)
- `RoutesApp`: Main controller with basic handlers
- Namespaced modules: Demonstrate complex class hierarchies
- Handlers return appropriate responses (JSON, HTML, redirects)

### Logic Classes (`app/logic/`)
- Simple classes: Basic business logic
- Nested classes: Show how Otto handles namespace resolution
- Parameterized logic: Demonstrate custom route parameters

## Next Steps

- Review the `routes` file for syntax reference
- Examine handler methods to see request/response patterns
- Check logic classes for business logic encapsulation patterns
- Explore [Authentication](../authentication_strategies/) for protecting routes
- See [Security Features](../security_features/) for CSRF, validation, file uploads

## Further Reading

- [Architecture Guide](../../docs/architecture.md) - How routing and response handling work
- [Best Practices](../../docs/best-practices.md) - Production patterns
- [Troubleshooting](../../docs/troubleshooting.md) - Common routing issues
- [Quickstart Guide](../../docs/quickstart.md) - Getting started tutorial
