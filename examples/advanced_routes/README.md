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

### Lambda / Inline Route Handlers (Issue #41)
Route to a proc that you **pre-register** by name, using the `&` prefix:
```
GET  /ping             &health_check            response=json
POST /webhook          &receive_webhook         response=json csrf=exempt
GET  /go               &to_dashboard            response=redirect
```

The `&name` token is a plain string key looked up (O(1)) in a registry you
supply at construction — the entire token after `&` is the key (dots, `#`, and
`::` are inert). Register the procs when you build Otto:
```ruby
otto = Otto.new('routes', lambda_handlers: {
  'health_check'   => ->(req, res, extra_params) {
    { status: 'ok', at: Time.now.to_i }        # response=json serializes this Hash
  },
  'receive_webhook' => ->(req, res, extra_params) {
    { received: true }
  },
  'to_dashboard'   => ->(req, res, extra_params) {
    '/dashboard'                                 # response=redirect uses this path
  },
})
```

The handler contract:

- Each proc is called with **`(req, res, extra_params)`** — `extra_params` is the
  hash of path captures (e.g. `:id` from `/users/:id`).
- The proc must accept 3 arguments (fixed arity `3`, or a splat/optional form).
  An invalid arity raises `ArgumentError` at construction.
- **All response types work** exactly as for controller routes:
  `response=json` (serializes a returned Hash), `response=view` (`to_s` as HTML),
  `response=redirect` (returned String is the `Location`), `response=auto`
  (content negotiation). With the default response type the proc must write to
  `res` directly, just like the other handler kinds.
- **Route options apply**: `csrf=exempt` (parse/expose parity with controllers),
  `auth=`, `role=`, and custom path params all flow through unchanged.

Security guarantee (the point of this feature): route files never carry code.
`&name` is only ever a name; there is **no `eval` and no dynamic constant
loading**. A route naming an unregistered handler fails with a clear
`ArgumentError` ("Lambda handler '...' is not registered or not callable")
instead of executing anything. The registered procs are, of course, trusted
code that you wrote.

Note: `csrf=exempt` is parse-and-expose parity with controller routes — the CSRF
middleware does not enforce it for any handler kind.

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

- [CLAUDE.md](../../CLAUDE.md) - Comprehensive developer guidance
