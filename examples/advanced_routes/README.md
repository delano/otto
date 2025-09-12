# Otto Advanced Routes Syntax

This example demonstrates the advanced routing syntax features added to Otto in v1.5.0+, focusing purely on the syntax without complex authentication.

## Features Demonstrated

### 1. Response Type Routes
- `response=json` - JSON API responses
- `response=view` - HTML view responses
- `response=redirect` - Redirect responses
- `response=auto` - Automatic content negotiation

### 2. CSRF Protection
- `csrf=exempt` - Exempt routes from CSRF protection (useful for APIs and webhooks)
- Default CSRF protection on POST/PUT/DELETE/PATCH routes

### 3. Logic Class Routes (New in v1.5.0+)
- `SimpleLogic` - Simple logic class routing
- `Admin::Panel` - Namespaced logic classes
- `Logic::Dashboard` - Deeply namespaced logic classes
- `Complex::Business::Handler` - Complex nested namespaces

### 4. Multiple Parameter Combinations
Routes can combine multiple parameters:
```
POST /api/v1/submit RoutesApp.api_submit response=json csrf=exempt
GET /logic/data DataLogic response=json
PUT /logic/transform TransformLogic response=json csrf=exempt
```

### 5. Namespaced Class Routes
- `Admin.show` - Class method with namespace
- `Modules::Auth#process` - Instance method with namespace
- `Handlers::Static.serve` - Mixed static and dynamic handlers

### 6. Custom Parameters
- `env=production` - Environment configuration
- `debug=true` - Debug flags
- `version=1.0` - Version parameters
- `feature=advanced mode=enabled` - Multiple custom parameters

## Route Syntax Reference

```
VERB /path TargetClass.method param1=value1 param2=value2
VERB /path TargetClass#method param1=value1 param2=value2
VERB /path LogicClassName param1=value1 param2=value2
VERB /path Namespace::LogicClass param1=value1 param2=value2
```

### Available Parameters

- `response=json|view|redirect|auto` - Response type
- `csrf=exempt` - Exempt from CSRF protection
- Custom parameters as needed by your application (e.g., `env=production`, `debug=true`)

## Running the Example

Choose one of these methods to run the example:

### Method 1: Using Rackup (Traditional)
```bash
cd examples/advanced_routes
bundle exec rackup config.ru
```

### Method 2: Direct Ruby with WEBrick
```bash
cd examples/advanced_routes
ruby run.rb
```

### Method 3: Using Puma Server
```bash
cd examples/advanced_routes
ruby puma.rb
```

### Method 4: Simple Test Runner (No Server)
```bash
cd examples/advanced_routes
ruby test.rb
```

2. Test different route types:

### Basic Routes
```bash
curl http://localhost:9292/
curl -X POST http://localhost:9292/feedback
```

### JSON API Routes
```bash
curl http://localhost:9292/api/users
curl -X POST http://localhost:9292/api/users
curl http://localhost:9292/api/health
curl -X PUT http://localhost:9292/api/users/123
curl -X DELETE http://localhost:9292/api/users/123
```

### View Routes
```bash
curl http://localhost:9292/dashboard
curl http://localhost:9292/reports
curl http://localhost:9292/admin
```

### Redirect Routes
```bash
curl -v http://localhost:9292/login
curl -v http://localhost:9292/logout
curl -v http://localhost:9292/home
```

### Auto Content Negotiation
```bash
# JSON response (default)
curl http://localhost:9292/data

# HTML response with Accept header
curl -H "Accept: text/html" http://localhost:9292/data
```

### CSRF Exempt API Routes
```bash
# These don't require CSRF tokens
curl -X POST http://localhost:9292/api/webhook
curl -X PUT http://localhost:9292/api/external
curl -X DELETE http://localhost:9292/api/cleanup
curl -X PATCH http://localhost:9292/api/sync
```

### Logic Class Routes
```bash
# Simple logic classes
curl http://localhost:9292/logic/simple
curl -X POST http://localhost:9292/logic/process
curl -X PUT http://localhost:9292/logic/validate

# Namespaced logic classes
curl http://localhost:9292/logic/admin
curl http://localhost:9292/logic/reports
curl -X POST http://localhost:9292/logic/analytics

# Logic classes with JSON responses
curl http://localhost:9292/logic/data
curl -X POST http://localhost:9292/logic/upload
curl -X PUT http://localhost:9292/logic/transform

# Complex namespaced logic
curl http://localhost:9292/logic/v2/dashboard
curl -X POST http://localhost:9292/logic/v2/process
curl http://localhost:9292/logic/admin/manager

# Deeply nested logic classes
curl http://localhost:9292/logic/nested/feature
curl -X POST http://localhost:9292/logic/complex/handler
curl -X PUT http://localhost:9292/logic/system/config
```

### Namespaced Class Routes
```bash
# Class methods
curl http://localhost:9292/v2/admin
curl -X POST http://localhost:9292/v2/config
curl -X PUT http://localhost:9292/v2/settings

# Instance methods
curl http://localhost:9292/modules/auth
curl -X POST http://localhost:9292/modules/validator
curl -X PUT http://localhost:9292/modules/transformer

# Mixed handlers
curl http://localhost:9292/handlers/static
curl -X POST http://localhost:9292/handlers/dynamic
curl -X PUT http://localhost:9292/handlers/async
```

### Custom Parameters
```bash
curl http://localhost:9292/config/env
curl http://localhost:9292/config/debug
curl -X POST http://localhost:9292/config/update

curl http://localhost:9292/feature/flags
curl -X POST http://localhost:9292/feature/toggle

curl http://localhost:9292/api/v1
curl http://localhost:9292/api/v2
curl -X POST http://localhost:9292/api/legacy
```

### Testing Routes
```bash
# Response type tests
curl http://localhost:9292/test/json
curl http://localhost:9292/test/view
curl -v http://localhost:9292/test/redirect
curl http://localhost:9292/test/auto

# CSRF tests
curl -X POST http://localhost:9292/test/csrf          # Requires CSRF token
curl -X POST http://localhost:9292/test/no-csrf      # CSRF exempt

# Logic class tests
curl http://localhost:9292/test/logic
curl -X POST http://localhost:9292/test/logic-json
curl -X PUT http://localhost:9292/test/logic-exempt

# Complex parameter combinations
curl http://localhost:9292/test/complex
curl -X POST http://localhost:9292/test/everything
```

## Logic Classes

Logic classes are a special routing target introduced in v1.5.0+. They:

1. Take a standard constructor: `initialize(context, params, locale)` where context is a RequestContext
2. Can implement `raise_concerns` for validation
3. Should implement `process` method for main logic
4. Can implement `response_data` for structured responses
5. Are automatically detected when the target contains no `.` or `#`

Example Logic class:
```ruby
class MyLogic
  attr_reader :context, :params, :locale

  def initialize(context, params, locale)
    @context = context
    @params = params
    @locale = locale
  end

  def process
    {
      result: 'processed',
      params: @params,
      authenticated: @context.authenticated?,
      user: @context.user_name,
      permissions: @context.permissions
    }
  end

  def response_data
    { logic_result: process }
  end
end
```

## Parameter Parsing

Route parameters are parsed as key=value pairs after the target class/method:

```
GET /path TargetClass.method param1=value1 param2=value2 param3=value3
```

### Special Cases
- Parameters without `=` are ignored (graceful handling of malformed params)
- Values can contain `=` signs: `config=key=value` becomes `{ config: "key=value" }`
- Multiple parameters are space-separated
- Parameter order doesn't matter

This provides a clean, readable syntax for configuring route behavior without complex configuration files.
