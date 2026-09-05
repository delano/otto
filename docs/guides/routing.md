# Routing applications with Otto

Otto keeps the application boundary small: a plain-text route file maps an HTTP
verb and path to a Ruby handler. Use this guide to choose a handler style and
response contract. The exact route grammar is in the [route syntax reference](../reference/route-syntax.md).

## Choose a handler style

| Use this when | Route target | Invocation |
| --- | --- | --- |
| You need a class method with direct Rack access | `App.index` | `App.index(req, res)` |
| You need an object with direct Rack access | `App#show` | `App.new(req, res).show` |
| You want a constrained, testable application operation | `App::Operation` | `App::Operation.new(strategy_result, params, locale)` |
| You need a small pre-registered endpoint function | `&name` | `call(req, res, captured_path_params)` |

## Controller-style handlers

Routes can call a class method or instantiate a class for an instance method:

```text
GET /                         App.index
GET /products/:id             App#show
```

```ruby
class App
  def initialize(req, res)
    @req = req
    @res = res
  end

  def show
    @res.body = "Product: #{@req.params[:id]}"
  end

  def self.index(req, res)
    res['content-type'] = 'text/plain'
    res.body = 'Hello Otto'
  end
end
```

Use this style when the handler needs cookies, request headers, the Rack
request object, or direct response helpers.

## Logic classes

Use a bare class target for an operation with an explicit input context:

```text
GET  /products/:id  Products::Show auth=session response=json
POST /products      Products::Create auth=session response=json
```

```ruby
class Products::Show
  def initialize(strategy_result, params, locale)
    @context = strategy_result
    @params = params
    @locale = locale
  end

  def raise_concerns
    @product = Product.find(@params[:id])
    unless @product.public? || @product.owner_id == @context.user_id
      raise Otto::Security::AuthorizationError, 'Product access denied'
    end
  end

  def process
    { id: @product.id, name: @product.name, locale: @locale }
  end
end
```

Otto runs `raise_concerns` before `process` when those methods exist. Put
resource loading and resource-level authorization in `raise_concerns`; route
authentication and broad role checks belong in the route definition.

Logic classes do not receive the Rack environment. This keeps their inputs
explicit and prevents application operations from depending on ambient request
state. Choose a controller-style handler when direct request access is part of
the operation.

## Registered lambda handlers

Lambda routes are useful for small endpoints that do not need a Ruby constant or
handler class. Register the callable at boot:

```ruby
otto = Otto.new('routes', lambda_handlers: {
  health_check: lambda do |_req, res, _extra_params|
    res['content-type'] = 'text/plain'
    res.body = 'ok'
  end,
})
```

```text
GET /health &health_check
```

The registry is normalized and frozen during configuration. A lambda must
accept three positional arguments: request, response, and captured path
parameters. Query and form parameters remain available through `req.params`.
The route name is an exact registry key; it is not evaluated as Ruby code.

## Response selection

Use `response=` when the handler returns a value that should pass through Otto's
response handling:

```text
GET  /api/products  Products::Index response=json
GET  /dashboard     Dashboard#show response=view
POST /login         Sessions#create response=redirect
GET  /data          Data#show response=auto
```

`response=default` is the default. Keep response selection in the route file
so the HTTP contract is visible beside the endpoint.

| Response type | Handler contract |
| --- | --- |
| `default` | Mutate `res` directly. The handler's return value is ignored. |
| `json` | Return a Hash for direct JSON serialization. `nil` becomes `{ "success": true }`; another value is wrapped as `data`. A Logic class may instead provide `response_data`. |
| `view` | Return a value rendered with `to_s`, or provide `view.render` on a Logic object. |
| `redirect` | Return a path String, or provide `redirect_path` on a Logic object. The fallback path is `/`. |
| `auto` | A Hash becomes JSON, a path-like String becomes a redirect, and a Logic object with `view` uses the view handler; other results use default behavior. |

An unknown response name currently falls back to `default`. Treat response
names as a fixed set; a typo otherwise changes the route to direct-response
behavior.

## Route parameters

Named path segments are available in request parameters:

```text
GET /products/:id  Products::Show
```

A handler can read `req.params[:id]` or a Logic class can read `params[:id]`.
Request query and body parameters are merged according to the handler's request
contract. JSON bodies are parsed for Logic-class parameters when the content
type is JSON and the body is a JSON object. A valid non-object JSON body is
ignored. Malformed JSON is logged and the Logic class still runs with its other
parameters; perform application validation when malformed JSON must return a
client error.

## Security options in routes

Authentication, roles, and CSRF exemptions are explicit route options:

```text
GET  /profile  Profile#show auth=session
GET  /admin    Admin::Dashboard auth=session role=admin
POST /hook     Hooks#receive csrf=exempt
```

Malformed `auth`, `role`, and `csrf` tokens fail route parsing rather than
silently weakening the route. Do not use `csrf=exempt` as a general API switch;
choose an independent request-authentication and replay-protection model for
webhooks or other non-browser endpoints.

## Configuration timing

Construct and configure the Otto instance before the first request:

```ruby
otto = Otto.new('routes')
otto.add_auth_strategy(
  'session',
  Otto::Security::Authentication::Strategies::SessionStrategy.new
)
otto.register_request_helpers(MyApp::RequestHelpers)
# Add middleware and other boot-time options here.
```

In normal operation, the first request freezes configuration. Runtime route or
security changes are not part of the application contract.
