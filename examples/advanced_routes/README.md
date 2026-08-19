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


## Key Features Demonstrated

### Response Types
Define how responses are formatted directly in routes:
```
GET  /api/users        RoutesApp#list_users      response=json
GET  /dashboard        RoutesApp#dashboard       response=view
GET  /login            RoutesApp#login_redirect  response=redirect
```

### Logic Classes
Route to specialized classes that encapsulate business logic:
```
GET  /logic/simple     SimpleLogic
GET  /logic/data       DataLogic       response=json
```

The classes in `app/logic/` expose the logic used by these routes.

### CSRF Exemption
Mark routes that don't need CSRF tokens (APIs, webhooks):
```
POST /api/webhook      RoutesApp#webhook_handler   csrf=exempt
```

### Namespaced Routing
Handle complex class hierarchies naturally:
```
GET  /logic/v2/dashboard  V2::Logic::Dashboard  response=view
GET  /logic/admin         Admin::Panel
```

### Custom Parameters
Add arbitrary key-value pairs for flexible routing:
```
GET  /feature/flags    RoutesApp#feature_flags  feature=advanced mode=enabled
```

These are route configuration values, not query-string parameters.

### Lambda / Inline Route Handlers (Issue #41)
Route to a proc that you **pre-register** by name, using the `&` prefix:
```
GET  /ping             &health_check            response=json
POST /hooks/receive    &receive_webhook         response=json csrf=exempt
GET  /go/dashboard     &to_dashboard            response=redirect
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

This example enables CSRF protection in `config.rb`; the `routes` file marks its API and webhook examples with `csrf=exempt`.

## Run it

### Prerequisites

Run this example from an Otto source checkout with Ruby 3.2 through 4.0 and Bundler. `rackup` is a development dependency in the root `Gemfile`, so enable that optional group before installing the bundle.

```sh
git clone https://github.com/delano/otto.git
cd otto
bundle config set with development
bundle install
cd examples/advanced_routes
bundle exec rackup config.ru
```

The server listens on `http://localhost:9292`.

> **Current limitation:** This checked-in example does not finish booting: `app/logic/complex/business/handler.rb` attempts to declare `Complex` as a module, which conflicts with Ruby's built-in `Complex` class. Until that source issue is fixed, `rackup` exits before listening and the checks below cannot be run. They document the routes and expected responses configured by this example.

### Verify routes

In another terminal, run these checks against routes defined in `routes`:

```sh
# JSON response
curl -i http://localhost:9292/api/health

# HTML view response
curl -i http://localhost:9292/dashboard

# Registered lambda handler
curl -i http://localhost:9292/ping

# Redirect response; inspect the Location header
curl -i http://localhost:9292/go/dashboard

# Route configuration values
curl -i http://localhost:9292/feature/flags
```

Expect `200` responses for the first three and last commands. `/api/health` returns JSON containing `healthy`, `/dashboard` returns HTML containing `Dashboard`, `/ping` returns JSON containing `ok`, and `/feature/flags` returns JSON containing `advanced`. `/go/dashboard` returns `302` with `Location: /dashboard`.

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
- Explore [Authentication](../authentication_strategies/README.md) for protecting routes
- See [Security Features](../security_features/README.md) for CSRF, validation, and file uploads

## Further Reading

- [Project README](../../README.md) - Installation and framework overview
