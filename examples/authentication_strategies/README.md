# Otto Authentication Strategies Example

This example demonstrates Otto's authentication and security features with advanced routing syntax.

## Features Demonstrated

### 1. Authentication Routes
- `auth=authenticated` - Simple authentication requirement
- `auth=role:admin` - Role-based authentication
- `auth=role:moderator` - Moderator role authentication
- `auth=permission:write` - Permission-based authentication
- `auth=permission:publish` - Publish permission requirement
- `auth=api_key` - Custom authentication strategy

### 2. Response Type Routes
- `response=json` - JSON API responses
- `response=view` - HTML view responses
- `response=redirect` - Redirect responses
- `response=auto` - Automatic content negotiation

### 3. CSRF Protection
- `csrf=exempt` - Exempt routes from CSRF protection (useful for APIs)
- Default CSRF protection on POST/PUT/DELETE routes

### 4. Logic Class Routes (New in v1.5.0+)
- `SimpleLogic` - Simple logic class routing
- `Admin::Logic::Panel` - Namespaced logic classes
- `V2::Logic::Admin::Dashboard` - Deeply namespaced logic classes

### 5. Multiple Parameter Combinations
Routes can combine multiple parameters:
```
GET /api/admin/users TestApp.admin_users auth=role:admin response=json
POST /api/secure TestApp.secure_post auth=authenticated response=json csrf=exempt
```

### 6. Namespaced Class Routes
- `V2::Admin::Panel.show` - Class method with namespace
- `Modules::AuthHandler#process` - Instance method with namespace

## Running the Example

1. Start the server:
```bash
cd examples/advanced_routes
bundle exec rackup config.ru
```

2. Test different routes with authentication tokens:

### Basic Routes
```bash
curl http://localhost:9292/
curl -X POST http://localhost:9292/feedback
```

### Authenticated Routes
```bash
# With authentication token
curl "http://localhost:9292/profile?token=demo_token"
curl -X POST "http://localhost:9292/profile?token=demo_token"

# Without token (should fail)
curl http://localhost:9292/profile
```

### Role-based Routes
```bash
# Admin role required
curl "http://localhost:9292/admin?token=admin_token"

# Moderator role required
curl "http://localhost:9292/moderator?token=mod_token"

# Wrong role (should fail)
curl "http://localhost:9292/admin?token=demo_token"
```

### Permission-based Routes
```bash
# Write permission required
curl "http://localhost:9292/edit?token=demo_token"

# Publish permission required (only admin has this)
curl -X POST "http://localhost:9292/publish?token=admin_token"
```

### JSON API Routes
```bash
# JSON responses
curl "http://localhost:9292/api/users"
curl -X POST "http://localhost:9292/api/users?token=demo_token"
curl "http://localhost:9292/api/health"
```

### CSRF Exempt API Routes
```bash
# These don't require CSRF tokens
curl -X POST "http://localhost:9292/api/webhook"
curl -X PUT "http://localhost:9292/api/external?api_key=demo_api_key_123"
curl -X DELETE "http://localhost:9292/api/cleanup?api_key=demo_api_key_123"
```

### Logic Class Routes
```bash
# Simple logic class
curl "http://localhost:9292/logic/simple?token=demo_token"

# Namespaced logic classes
curl "http://localhost:9292/logic/admin?token=admin_token"
curl "http://localhost:9292/logic/reports?token=read_token"

# Logic classes with JSON responses
curl -X POST "http://localhost:9292/logic/processor?token=demo_token"
curl -X PUT "http://localhost:9292/logic/validator?token=demo_token"
```

### Complex Logic Routes
```bash
# V2 namespaced logic with view response
curl "http://localhost:9292/logic/dashboard?token=admin_token"

# Analytics logic with JSON response (CSRF exempt)
curl -X POST "http://localhost:9292/logic/analytics?token=admin_token"
```

## Authentication Tokens

The example includes several test tokens:

- `demo_token` - Regular user with basic permissions
- `admin_token` - Admin user with all permissions
- `mod_token` - Moderator user with moderate permissions
- `read_token` - Read-only user
- `test_token` - Test user for testing routes
- `demo_api_key_123` - API key for API routes (use as `api_key` parameter or `X-API-KEY` header)

## Route Syntax Reference

```
VERB /path TargetClass.method param1=value1 param2=value2
VERB /path TargetClass#method param1=value1 param2=value2
VERB /path LogicClassName param1=value1 param2=value2
VERB /path Namespace::LogicClass param1=value1 param2=value2
```

### Available Parameters

- `auth=strategy_name` - Authentication requirement
- `auth=role:role_name` - Role-based authentication
- `auth=permission:perm_name` - Permission-based authentication
- `response=json|view|redirect|auto` - Response type
- `csrf=exempt` - Exempt from CSRF protection
- Custom parameters as needed by your application

## Logic Classes

Logic classes are a special routing target introduced in v1.5.0+. They:

1. Take a standard constructor: `initialize(session, user, params, locale)`
2. Can implement `raise_concerns` for validation
3. Should implement `process` method for main logic
4. Can implement `response_data` for structured responses
5. Are automatically detected when the target contains no `.` or `#`

Example Logic class:
```ruby
class MyLogic
  attr_reader :session, :user, :params, :locale

  def initialize(session, user, params, locale)
    @session = session
    @user = user
    @params = params
    @locale = locale
  end

  def raise_concerns
    # Validation logic
  end

  def process
    # Main business logic
    { result: 'processed' }
  end

  def response_data
    { logic_result: process }
  end
end
```

This provides a clean separation of concerns and standardized interface for business logic handling.
