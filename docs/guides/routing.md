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

## Static files

Otto serves static files in two ways. Both apply the same safety policy: the
requested path is joined to a canonical root, resolved with `File.realpath`
(which follows every `..`, `.`, and symlink component), and served only when
the result is still inside that root and is a regular, readable file owned by
the process user or group. Anything else, including a symlink that points
outside the root, is treated as not found.

### Implicit public directory

Passing `public:` serves every file under that directory at its relative path.
Nothing needs registering; a file added after boot is served on the next
request, and a symlinked public directory that is repointed by a deploy is
re-resolved on every request.

```ruby
otto = Otto.new('routes', public: File.expand_path('public', __dir__))
# public/css/site.css is served at GET /css/site.css
```

### Explicit static mounts

`mount_static` binds one URL prefix to one directory. Use it when the files do
not live under a single public directory, when a URL prefix should map to a
different directory name, or when a required asset directory must be verified
at boot.

```ruby
otto = Otto.new('routes')
otto.mount_static('/assets', root: 'public/assets')
otto.mount_static('/vendor', root: File.join(Gem.loaded_specs['some-ui-kit'].full_gem_path, 'dist'))
otto.mount_static('/', root: 'public/root-files') # favicon.ico, robots.txt
```

- The prefix must start with `/`. A trailing slash is ignored, and `/`
  mounts the root at the top level. Empty, `.`, and `..` segments are
  rejected.
- The root is expanded and canonicalized once, at registration. A root that
  is missing, unreadable, not a directory, not owned by the process user or
  group, or a symlink that cannot be resolved raises `ArgumentError`, so a
  misconfigured application does not boot. Because the root is fixed at
  registration, a deploy that repoints a symlinked root takes effect at the
  next restart.
- A mount authorizes only files inside its own root. It never exposes the
  root's parent or siblings, and it does not widen the implicit public
  directory. Registering the same prefix twice on one instance raises
  `ArgumentError`; different Otto instances are fully independent.
- Requests are matched on the decoded, trailing-slash-stripped path, the same
  normalization every other dispatch stage uses. Only `GET` is served, the
  prefix itself is not (mounts serve files, not directory listings), and a
  request for a file the root does not contain falls through to the next
  dispatch stage.
- `mount_static` must be called before the first request. After configuration
  freezing it raises `FrozenError`, and `otto.static_mounts` is a frozen,
  read-only table.

### Dispatch precedence

Precedence is fixed and does not depend on request history:

1. literal routes, such as `GET /assets/app.css Assets#show`;
2. explicit static mounts, consulted longest prefix first; when the longest
   matching mount does not contain the file, shorter matching mounts are tried
   in turn;
3. the implicit `public:` directory;
4. dynamic routes, such as `GET /assets/:name Assets#show`.

So a literal route at a mounted path always wins, a mounted file always beats
a file at the same URL in the public directory, and a dynamic route only sees
requests that no static source could serve.

### Migrating from `add_static_path`

`add_static_path` was removed in v2.10.0. It only populated a request-time
cache; it never registered or restricted anything. Callers that used it to
"register" files under the public directory can delete the call, because the
public directory is served without registration. Callers that used it to reach
files outside the public directory should replace it with `mount_static` and
an explicit root. There is no compatibility shim: calling the removed method
raises `NoMethodError` at boot.

## Fallback 404 and 500 responses

A `GET /404` or `GET /500` route in the routes file handles misses and
unhandled errors like any other route. Without one, Otto uses `not_found=` and
`server_error=`, which accept either a Rack triple or a callable:

```ruby
otto.not_found = [404, { 'content-type' => 'application/json' }, ['{"error":"Not Found"}']]

otto.server_error = lambda do |env, error|
  [500, { 'content-type' => 'text/plain' }, ["Error #{env['otto.error_id']}"]]
end
```

A callable is invoked on every request with `env` (`not_found`) or `env` and
the exception (`server_error`), trimmed to the positional parameters it
declares, so `->(env) { ... }` and `->(env = nil) { ... }` both work for
`server_error`. It must return a Rack triple: an Integer status, Hash-like
headers, and a body that responds to `each` (a bare String is rejected, at
assignment time for a static triple). A static triple is copied per request
before it is returned, so middleware that writes response headers in place
(rack-session, Otto's CSRF middleware, anything calling
`Rack::Utils.set_cookie_header!`) never mutates the configured object or
leaks one client's `Set-Cookie` into another's response. Do not rely on
mutating the configured triple after boot; assign a new value or use the
callable form instead.

For JSON clients, an unhandled error returns Otto's built-in JSON error body
regardless of `server_error`; a `/500` route applies to every client.

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
