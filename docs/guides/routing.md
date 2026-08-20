# Routing applications with Otto

Otto keeps the application boundary small: a plain-text route file maps an HTTP
verb and path to a Ruby handler. Use this guide to choose a handler style and
response contract. The exact route grammar is in the [route syntax reference](../reference/route-syntax.md).

## Choose a handler style

| Use this when | Route target | Handler receives |
| --- | --- | --- |
| You need direct Rack request/response access and a small controller-style method | `App#index` or `App#show` | `req`, `res` |
| You want a constrained, testable application operation | `App::Operation` | authentication result, merged params, locale |
| You need a small pre-registered endpoint function | `&name` | `req`, `res`, extra params |

## Controller-style handlers

Routes can call a class method or instantiate a class for an instance method:

```text
GET /                         App#index
GET /products/:id             App#show
GET /robots.txt               App.robots
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
accept three positional arguments: request, response, and extra parameters.
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

## Route parameters

Named path segments are available in request parameters:

```text
GET /products/:id  Products::Show
```

A handler can read `req.params[:id]` or a Logic class can read `params[:id]`.
Request query and body parameters are merged according to the handler's request
contract. JSON bodies are parsed for Logic-class parameters when the content
type is JSON and the body is a JSON object.

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
otto.add_auth_strategy('session', SessionStrategy.new)
otto.register_request_helpers(MyApp::RequestHelpers)
# Add middleware and other boot-time options here.
```

In normal operation, the first request freezes configuration. Runtime route or
security changes are not part of the application contract.
