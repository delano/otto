# Otto Architecture Guide

Understanding how Otto processes requests and manages configuration.

## Request Flow

```
HTTP Request
    ↓
Rack (config.ru)
    ↓
Otto::MiddlewareStack
    ├─ IPPrivacyMiddleware (masks public IPs, anonymizes user agents)
    ├─ CSRFMiddleware (validates/generates CSRF tokens)
    ├─ ValidationMiddleware (validates request size/params)
    └─ RateLimitMiddleware (enforces rate limits)
    ↓
Otto::Router (route matching)
    ├─ Literal routes (exact match, fastest)
    ├─ Static routes (prefix match)
    └─ Dynamic routes (parameter capture)
    ↓
RouteAuthWrapper (if route requires auth)
    ├─ Loads auth strategy
    ├─ Executes strategy.authenticate
    └─ Sets req.user_context on success
    ↓
Route Handler (class method, instance method, lambda, or logic class)
    ├─ Instantiate if needed
    ├─ Call method with (req, res)
    └─ Handle response
    ↓
Response Handler (negotiates content type)
    ├─ JSON response
    ├─ View/template response
    ├─ Redirect response
    └─ Default response
    ↓
HTTP Response (sent to client)
```

## Routes File Parsing

The routes file is a plain-text manifest that Otto parses on initialization:

```
METHOD  PATH              TARGET                  [options]
GET     /                 App#index
POST    /users            App#create_user         csrf=exempt
GET     /users/:id        App#show_user           response=json
GET     /admin            AdminPanel#dashboard    auth=admin
```

### Parsing Components

1. **HTTP Method**: GET, POST, PUT, DELETE, PATCH, etc.
2. **Path Pattern**:
   - Literal: `/about` (exact match, O(1) lookup in Set)
   - Static: `/public/*` (prefix match)
   - Dynamic: `/users/:id` (captures parameters)
3. **Target**: Class name or Class#method mapping
4. **Options**: key=value pairs for routes (csrf, response, auth, custom)

### Target Resolution

Otto supports multiple target formats:

```ruby
# Class method
GET  /users    User.list

# Instance method (creates new instance)
GET  /users    UserController#list

# Logic class (auto-instantiates and calls #process)
GET  /data     DataProcessor

# Namespaced classes
GET  /v2/users  V2::API::UsersController#index
```

## Configuration Freezing

Otto automatically freezes configuration after the first request to prevent security bypasses:

1. **Lazy Freezing**: Configuration is frozen on first request, not at initialization
2. **Thread-Safe**: Uses mutex to ensure exact-once freezing
3. **Deep Freezing**: Recursively freezes all nested structures
4. **Multi-Step Init**: Allows adding strategies/middleware before first request

```ruby
# Before first request: can add configuration
otto = Otto.new(routes)
otto.add_auth_strategy('token', TokenStrategy.new)
otto.enable_csrf_protection!

# After first request: all configuration is frozen
# FrozenError will be raised if you try to modify:
# - Security config
# - Middleware stack
# - Routes
# - Auth strategies
```

See [CLAUDE.md](../CLAUDE.md#configuration-freezing) for details.

## Privacy Middleware

The IPPrivacyMiddleware is the first middleware in the stack, protecting privacy before any other processing:

```ruby
# For public IPs (e.g., 203.0.113.50):
env['REMOTE_ADDR']              # => '203.0.113.0' (masked)
env['HTTP_USER_AGENT']          # => 'Mozilla/*.* Windows ...' (versions stripped)
env['HTTP_REFERER']             # => 'https://example.com/page' (query params stripped)
env['otto.privacy.masked_ip']   # => '203.0.113.0'
env['otto.privacy.hashed_ip']   # => 'a3f8b2...' (daily-rotating)
env['otto.privacy.geo_country'] # => 'US' (country code only)

# For private IPs (e.g., 127.0.0.1, 192.168.1.x):
env['REMOTE_ADDR']              # => '127.0.0.1' (unchanged)
env['HTTP_USER_AGENT']          # => '...' (unchanged)
env['otto.original_ip']         # => '127.0.0.1' (for debugging)
```

**Why first?** Because logging/monitoring middleware runs after this in the stack, they automatically get masked values. No accidental IP leaks to logs or error tracking.

See [CLAUDE.md](../CLAUDE.md#ip-privacy-privacy-by-default) for configuration details.

## Authentication Architecture

Authentication is handled by `RouteAuthWrapper` at the route handler level (not middleware):

```ruby
# In routes file
GET  /admin  AdminController#dashboard  auth=admin

# When request arrives:
# 1. RouteAuthWrapper intercepts
# 2. Looks up 'admin' strategy from auth_config[:auth_strategies]
# 3. Calls strategy.authenticate(env, 'admin')
# 4. If success: sets env['otto.user'], calls handler
# 5. If failure: returns 401/302 redirect
```

### Strategy Pattern Matching

Strategies support intelligent matching:

```ruby
# Exact match
auth=authenticated  # Looks up strategy named 'authenticated'

# Prefix match (useful for role-based)
auth=role:admin     # Looks up strategy named 'role'
                    # Passes 'admin' to strategy

# Fallback
auth=role:*         # Creates default RoleStrategy if not found
```

See [CLAUDE.md](../CLAUDE.md#authentication-architecture) for detailed patterns.

## Response Handling

Otto supports automatic response type negotiation based on route options or Accept header:

```ruby
# Routes file
GET  /users        UsersController#list  response=json
GET  /about        App#about             response=view
GET  /old-page     App#new-page          response=redirect
```

### Response Handlers

1. **JSON Handler**: Converts Ruby objects to JSON
2. **View Handler**: Renders templates (not included, app-provided)
3. **Redirect Handler**: Sets Location header and status 302
4. **Default Handler**: Uses body as-is

### Content Negotiation

If no explicit response type is set, Otto checks the Accept header:

```ruby
def list
  data = [{ id: 1, name: 'Item 1' }]
  @res.body = data  # Will be JSON if Accept: application/json
end
```

See `lib/otto/response_handlers/` for implementation.

## Middleware Stack

The middleware stack is a Rack-compatible list processed for each request:

```ruby
# Built-in middleware (added by Otto)
IPPrivacyMiddleware        # First - protects privacy
CSRFMiddleware             # If csrf_protection enabled
ValidationMiddleware       # If request_validation enabled
RateLimitMiddleware        # If rate limiting enabled

# Custom middleware (added by app)
otto.use MyCustomMiddleware
otto.use Rack::Compression
```

Middleware is added via:

```ruby
otto = Otto.new(routes)
otto.use MyMiddleware
otto.use AnotherMiddleware
# Configuration freezes on first request
```

All middleware must be added BEFORE the first request.

## Error Handling

Otto provides two error handling paths:

### 1. Registered Errors (Expected Business Logic Errors)

```ruby
otto.register_error_handler(MissingResource, status: 404, log_level: :info)

# When raised:
# - Returns configured status code (not 500)
# - Logs at specified level (:info, not :error)
# - No backtrace
```

### 2. Unhandled Errors

```ruby
# When raised:
# - Returns 500 Internal Server Error
# - Logs with backtrace
# - Generates error ID for tracking
```

See [CLAUDE.md](../CLAUDE.md#error-handler-registration) and [docs/best-practices.md](best-practices.md#error-handling) for patterns.

## Structured Logging

Otto provides helpers for consistent structured logging with request context:

```ruby
Otto.structured_log(:info, "User created",
  Otto::LoggingHelpers.request_context(env).merge(
    user_id: user.id,
    duration: time_elapsed_μs
  )
)
```

All timing is in microseconds (`Otto::Utils.now_in_μs`).

See [CLAUDE.md](../CLAUDE.md#structured-logging-conventions) for detailed patterns.

## Multi-App Architectures

Otto supports multiple instances via Rack::URLMap:

```ruby
# config.ru
app1 = Otto.new("./app1/routes")
app2 = Otto.new("./app2/routes")

map = Rack::URLMap.new(
  "/app1" => app1,
  "/app2" => app2
)

run map
```

**Important**:
- Each Otto instance has its own isolated configuration
- Callbacks (e.g., `on_request_complete`) are instance-level, not class-level
- Configuration is frozen per-instance after first request to that instance
- Privacy middleware runs once per request (idempotent if called multiple times)

See [CLAUDE.md](../CLAUDE.md#multi-app-architectures) for patterns.

## Proxy Support

Otto supports trusted proxies for X-Forwarded-For header resolution:

```ruby
otto.add_trusted_proxy('10.0.0.1')              # Exact IP
otto.add_trusted_proxy(/^192\.168\./)           # Regex
otto.add_trusted_proxy('172.16.0.0/12')         # CIDR (planned)

# With trusted proxy:
# env['REMOTE_ADDR'] = '10.0.0.1'
# env['HTTP_X_FORWARDED_FOR'] = '203.0.113.50'
#
# Result after privacy middleware:
# env['REMOTE_ADDR'] = '203.0.113.0' (resolved and masked)
```

See [CLAUDE.md](../CLAUDE.md#proxy-support) for security considerations.

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Route Matching | O(1) literal, O(n) dynamic | Literal routes use Set for fast lookup |
| Middleware Stack | O(n) | Linear per middleware in stack |
| Authentication | O(1) | Strategy lookup via hash |
| Response Handling | O(1) | Handler selection by content type |
| Privacy Masking | O(1) | Bitwise operations for IP masking |
| Configuration Freeze | O(n) | Recursive freezing of all structures |

## Key Design Decisions

1. **Plain-Text Routes**: Reduces configuration complexity, easier to understand
2. **Route Parsing at Init**: Routes are parsed once at startup, not per-request
3. **Lazy Configuration Freezing**: Allows multi-step initialization before security lock-down
4. **Middleware-First Privacy**: Privacy is the first middleware so downstream code automatically gets safe values
5. **Instance-Level Auth**: RouteAuthWrapper at route level enables flexible per-route strategies
6. **Automatic Response Negotiation**: Reduces boilerplate in handlers
7. **Structured Logging**: Consistent format makes parsing and analysis easier

## Extending Otto

Common extension patterns:

### Custom Middleware

```ruby
class MyMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    # Before request
    status, headers, body = @app.call(env)
    # After request
    [status, headers, body]
  end
end

otto.use MyMiddleware
```

### Custom Response Handler

```ruby
class MyHandler < Otto::ResponseHandlers::Base
  def matches?
    # Check if this handler should handle the response
  end

  def handle(body, headers, status)
    # Transform response
  end
end

Otto.register_response_handler(MyHandler)
```

### Custom Authentication Strategy

```ruby
class MyStrategy < Otto::Security::Authentication::AuthStrategy
  def authenticate(env, requirement)
    # Validate and return StrategyResult
  end
end

otto.add_auth_strategy('my_auth', MyStrategy.new)
```

See [CLAUDE.md](../CLAUDE.md#authentication-architecture) for detailed implementation guides.

## Debugging

Enable debug mode for verbose logging:

```ruby
Otto.debug = true
otto = Otto.new(routes)
# All Otto.structured_log calls with :debug level will be logged
```

Check environment values at any point:

```ruby
# In a route handler
def debug_route
  puts env['REMOTE_ADDR']          # Masked IP
  puts env['otto.privacy']         # Privacy metadata
  puts @req.user_context           # Auth info
  puts env.keys                     # All env keys
end
```

## Further Reading

- [CLAUDE.md](../CLAUDE.md) - Comprehensive architectural documentation
- [docs/best-practices.md](best-practices.md) - Production patterns
- [docs/troubleshooting.md](troubleshooting.md) - Common issues
- [examples/advanced_routes/](../examples/advanced_routes/) - Advanced routing patterns
- [examples/authentication_strategies/](../examples/authentication_strategies/) - Auth implementation examples
