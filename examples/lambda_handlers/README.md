# Otto - Lambda / Inline Route Handlers

This example demonstrates Otto's fourth route-handler kind (issue #41):
**lambda handlers**. A lambda handler is a plain proc, pre-registered by name,
that a route can target with an `&` prefix.

## What You'll Learn

- Registering lambda handlers at `Otto.new` construction time
- The `&handler_name` route syntax
- Returning strings, Hashes (JSON), and mutating the response directly
- Applying route options (`response=json`, `csrf=exempt`) to lambdas
- Why this is safe: no `eval`, no dynamic code from route files

## The Four Handler Kinds

| Route target    | Kind        | Resolves to             |
|-----------------|-------------|-------------------------|
| `App.index`     | `:class`    | class method            |
| `App#index`     | `:instance` | instance method         |
| `BareClass`     | `:logic`    | Logic object            |
| `&health_check` | `:lambda`   | pre-registered proc     |

## Registration

Lambdas are supplied to Otto as a `name => callable` Hash. Otto validates each
entry (must respond to `#call`, must accept 3 arguments) and freezes the
registry:

```ruby
require_relative '../../lib/otto'
require_relative 'handlers'

app = Otto.new('routes', {
  lambda_handlers: LambdaHandlers::REGISTRY,
})
```

Each handler receives `(req, res, extra_params)`:

```ruby
HEALTH_CHECK = lambda do |req, res, extra_params|
  res.headers['content-type'] = 'text/plain; charset=utf-8'
  res.body = 'OK'
end
```

## Route Syntax

Prefix the target with `&` and give the registered name. Everything after the
`&` is the exact registry key. The target comes first; route options follow it:

```
GET   /ping           &health_check
GET   /status         &status    response=json
GET   /greet/:name    &greet     response=json
POST  /webhook        &webhook   csrf=exempt response=json
```

## Response Types

Lambdas participate in Otto's normal response-type dispatch, the same way a
class/instance/logic handler does:

- **Default** (no `response=`): the handler mutates `res` directly — set
  `res.status` / `res.headers` / `res.body`. The return value is ignored, so
  writing `res.body` is what produces output.
- **`response=json`**: the returned Hash is serialized as JSON and the JSON
  content-type is set for you.

## Route Options

Route options apply to lambdas just like any other handler:

- `response=json` — serialize the returned Hash as JSON.
- `csrf=exempt` — parsed and exposed on the route definition (intended to mark
  the webhook, which external callers reach without a browser token). Note:
  `CSRFMiddleware` does not yet consult per-route options, so this option is
  currently recorded but not enforced — see issue #186.
- `auth=` / `role=` — authentication and authorization (when `auth_config`
  is configured on the Otto instance).

## Security

The `&` syntax performs an O(1) lookup of a **pre-registered** proc by name.
Route files never contain Ruby code and are never `eval`'d. A route naming a
handler that was not registered raises a clear error instead of executing
anything.

## How to Run

```sh
cd examples/lambda_handlers
rackup config.ru -p 10780
```

Then, from another terminal:

```sh
curl localhost:10780/ping
# OK

curl localhost:10780/status
# {"service":"otto-lambda-demo","status":"healthy","time":"..."}

curl localhost:10780/greet/otto
# {"greeting":"Hello, otto!"}

curl -X POST --data 'hello' localhost:10780/webhook
# {"received":true,"bytes":5}
```

## File Structure

- `README.md`: This file.
- `handlers.rb`: Defines the lambda procs and the `REGISTRY` Hash.
- `routes`: Maps URLs to lambdas using the `&` syntax.
- `config.ru`: Rack config that registers the lambdas with `Otto.new`.

## Next Steps

- Explore [Advanced Routes](../advanced_routes/) for class/instance/logic
  handlers and response-type negotiation.
- See [Security Features](../security_features/) for CSRF and input validation.

## Further Reading

- [docs/ADVANCED_ROUTES.txt](../../docs/ADVANCED_ROUTES.txt)
