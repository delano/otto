# Otto Best Practices

Production-ready patterns for building Otto applications.

## Error Handling

### Register Expected Business Logic Errors

Instead of returning 500 errors for expected business exceptions, register them to return appropriate status codes:

```ruby
# config.ru
otto = Otto.new(routes)

# Register expected errors
otto.register_error_handler(MissingResource, status: 404, log_level: :info)
otto.register_error_handler(ResourceExpired, status: 410, log_level: :info)
otto.register_error_handler(RateLimited, status: 429, log_level: :warn)
otto.register_error_handler(PermissionDenied, status: 403, log_level: :warn)

otto.enable_csrf_protection!
```

### Custom Error Response Handlers

For more control over error responses, provide a block:

```ruby
otto.register_error_handler(ValidationError, status: 422, log_level: :warn) do |error, req|
  {
    error: 'Validation failed',
    message: error.message,
    field: error.field,
    details: error.details
  }
end
```

### Error Handling in Route Handlers

Implement validation and raise registered errors:

```ruby
class UsersController
  def create
    # Validate input
    raise ValidationError.new("Email required") if @req.params[:email].empty?
    raise ValidationError.new("Invalid email") unless valid_email?(@req.params[:email])

    # Create user...
    user = User.create(...)

    @res.status = 201
    @res.body = JSON.generate({ id: user.id })
  rescue ValidationError => e
    raise  # Will be caught by registered error handler
  end
end
```

See [CLAUDE.md](../CLAUDE.md#error-handler-registration) for complete error registration guide.

---

## Structured Logging

### Use Request Context for Consistency

Always include request context in structured logs:

```ruby
class UsersController
  def create
    start_time = Otto::Utils.now_in_μs

    # Validate and create user...
    user = User.create(@req.params)

    duration = Otto::Utils.now_in_μs - start_time

    Otto.structured_log(:info, "User created",
      Otto::LoggingHelpers.request_context(@env).merge(
        user_id: user.id,
        email: user.email,
        duration: duration
      )
    )

    @res.status = 201
    @res.body = JSON.generate({ id: user.id })
  end
end
```

### Use `log_timed_operation` for Operations

Automatic timing and error handling:

```ruby
def import_users
  result = Otto::LoggingHelpers.log_timed_operation(:info, "Import users", @env,
    source: @req.params[:source],
    count: users_to_import.length
  ) do
    # Heavy operation here
    users = import_from_api
    save_to_database(users)
    users
  end

  # If operation failed, exception is logged and re-raised
  @res.body = JSON.generate({ imported: result.length })
end
```

### Consistent Timing Units

Always use microseconds for all timing:

```ruby
# ✅ Good - all in microseconds
start = Otto::Utils.now_in_μs
result = expensive_operation
duration = Otto::Utils.now_in_μs - start

Otto.structured_log(:info, "Operation done",
  Otto::LoggingHelpers.request_context(@env).merge(
    operation: 'expensive',
    duration: duration  # In microseconds
  )
)

# ❌ Bad - mixing units
duration_ms = (time_now - start) / 1000.0
Otto.structured_log(:info, "Operation done", { duration_ms: duration_ms })
```

See [CLAUDE.md](../CLAUDE.md#structured-logging-conventions) for detailed logging guide.

---

## Security

### Enable Security Features by Default

```ruby
# config.ru
otto = Otto.new(routes)

# Enable standard security features
otto.enable_csrf_protection!

# Configure request limits
otto.security_config.request_size_limit = 1.megabyte
otto.security_config.max_parameter_keys = 100
otto.security_config.max_parameter_depth = 5

# Add trusted proxies if behind a reverse proxy
otto.add_trusted_proxy('10.0.0.0/8')
otto.add_trusted_proxy(/^192\.168\./)

# Custom security headers
otto.add_security_header('X-Custom-Header', 'value')
```

### Input Validation

Validate all user input in handlers:

```ruby
class FeedbackController
  MAX_MESSAGE_LENGTH = 1000

  def create
    message = @req.params[:message]

    # Validate input
    raise ValidationError.new("Message required") if message.nil? || message.empty?
    raise ValidationError.new("Message too long") if message.length > MAX_MESSAGE_LENGTH
    raise ValidationError.new("Invalid characters") if message =~ /[<>]/

    # Safe to use now
    feedback = Feedback.create(message: message)

    @res.status = 201
    @res.body = JSON.generate({ id: feedback.id })
  end
end
```

### File Upload Handling

Sanitize filenames and validate file types:

```ruby
require 'fileutils'

class DocumentController
  ALLOWED_TYPES = ['application/pdf', 'image/png', 'image/jpeg']
  MAX_FILE_SIZE = 10.megabytes

  def upload
    file = @req.params[:document]

    # Validate file
    raise FileError.new("File required") if file.nil?
    raise FileError.new("File too large") if file[:tempfile].size > MAX_FILE_SIZE
    raise FileError.new("File type not allowed") unless ALLOWED_TYPES.include?(file[:type])

    # Sanitize filename
    filename = sanitize_filename(file[:filename])

    # Save safely
    safe_path = File.join('uploads', filename)
    FileUtils.cp(file[:tempfile].path, safe_path)

    @res.status = 201
    @res.body = JSON.generate({ filename: filename })
  end

  private

  def sanitize_filename(filename)
    # Remove path components and dangerous characters
    File.basename(filename)
      .gsub(/[^\w.-]/, '_')
      .gsub(/^\.+/, '')  # Remove leading dots
  end
end
```

### Secure Password Handling

Never log or expose passwords:

```ruby
class AuthController
  def login
    # ✅ Good - password never logged
    email = @req.params[:email]
    password = @req.params[:password]

    user = User.authenticate(email, password)
    raise AuthError.new("Invalid credentials") unless user

    # Log only what's necessary
    Otto.structured_log(:info, "User login",
      Otto::LoggingHelpers.request_context(@env).merge(
        user_id: user.id,
        email: user.email  # Never log password
      )
    )

    @res.body = JSON.generate({ user_id: user.id })
  end
end

# ❌ Bad - password logged
Otto.structured_log(:info, "Login attempt",
  email: @req.params[:email],
  password: @req.params[:password]  # NEVER!
)
```

---

## Authentication

### Multi-Strategy Authentication

Support multiple authentication methods:

```ruby
# config.ru
otto = Otto.new(routes)

# Token-based auth
otto.add_auth_strategy('token', Otto::Security::Authentication::Strategies::TokenStrategy.new(
  tokens: load_tokens_from_database
))

# API key auth
otto.add_auth_strategy('api_key', Otto::Security::Authentication::Strategies::APIKeyStrategy.new(
  keys: load_api_keys_from_database
))

# Session-based auth
otto.add_auth_strategy('session', SessionStrategy.new(
  session_key: 'user_id'
))

# Role-based access
otto.add_auth_strategy('role', RoleStrategy.new(
  roles: load_user_roles_from_database
))
```

### Dynamic Token Validation

Load tokens from database instead of hardcoding:

```ruby
class TokenStrategy < Otto::Security::Authentication::AuthStrategy
  def initialize
    @tokens = {}
    @cache_expires_at = Time.now
  end

  def authenticate(env, requirement)
    # Refresh cache periodically
    refresh_tokens_if_needed

    token = env['QUERY_STRING'].match(/token=([^&]+)/)[1]
    return failure_result unless token && @tokens.key?(token)

    user_data = @tokens[token]
    success_result(user_id: user_data[:user_id], roles: user_data[:roles])
  end

  private

  def refresh_tokens_if_needed
    return if Time.now < @cache_expires_at

    @tokens = load_valid_tokens_from_database
    @cache_expires_at = Time.now + 5.minutes
  end
end
```

See [CLAUDE.md](../CLAUDE.md#authentication-architecture) for detailed auth patterns.

---

## Performance Optimization

### Use Logic Classes for Heavy Computation

Move complex logic into dedicated classes:

```ruby
# routes
GET  /expensive-operation  ExpensiveLogic

# app.rb
class ExpensiveLogic
  def process(req, res)
    # Heavy computation happens here
    # Isolated from other request processing
    result = expensive_calculation(req.params)

    res.body = JSON.generate(result)
  end

  private

  def expensive_calculation(params)
    # Complex logic...
  end
end
```

### Cache Frequently Accessed Data

```ruby
class DataController
  @@cache = {}
  @@cache_expires_at = {}

  def show
    data_id = @req.params[:id]

    # Check cache
    if cached = fetch_from_cache(data_id)
      @res.body = JSON.generate(cached)
      return
    end

    # Load from database
    data = load_data(data_id)
    save_to_cache(data_id, data)

    @res.body = JSON.generate(data)
  end

  private

  def fetch_from_cache(key)
    return nil unless @@cache.key?(key)
    return nil if Time.now > @@cache_expires_at[key]
    @@cache[key]
  end

  def save_to_cache(key, value)
    @@cache[key] = value
    @@cache_expires_at[key] = Time.now + 10.minutes
  end
end
```

### Use Appropriate Response Types

Reduce serialization overhead:

```ruby
# routes
GET  /users        UsersController#list      response=json
GET  /users/:id    UsersController#show      response=json
GET  /about        PageController#about      response=view
GET  /old-url      PageController#new-url    response=redirect

# Handler returns raw data, Otto handles serialization
class UsersController
  def list
    # Just return the data, Otto serializes to JSON
    @res.body = User.all
  end
end
```

---

## Configuration Management

### Configuration Before First Request

Otto freezes configuration after the first request:

```ruby
# ✅ Good - configuration before first request
otto = Otto.new(routes)
otto.add_auth_strategy('token', MyStrategy.new)
otto.enable_csrf_protection!
otto.add_trusted_proxy('10.0.0.0/8')

app = Rack::Builder.new do
  run otto
end

# ❌ Bad - configuration after first request
app.call(env)  # First request - freezes configuration
otto.add_auth_strategy('api_key', APIKeyStrategy.new)  # FrozenError!
```

### Environment-Specific Configuration

```ruby
# config.ru
otto = Otto.new(routes)

case ENV['RACK_ENV']
when 'development'
  otto.disable_ip_privacy!  # See real IPs in dev
  Otto.debug = true

when 'production'
  # All security features enabled by default
  otto.enable_csrf_protection!
  otto.configure_ip_privacy(octet_precision: 2)  # Mask more aggressively

  # Load from secure sources
  strategies = load_auth_strategies_from_vault
  strategies.each { |name, strategy| otto.add_auth_strategy(name, strategy) }
end

run otto
```

---

## Multi-App Architectures

### Using Rack::URLMap

For complex applications with multiple Otto instances:

```ruby
# config.ru
require 'rack'
require 'otto'

# Create independent Otto instances
api_app = Otto.new('api/routes')
api_app.add_auth_strategy('api_key', APIKeyStrategy.new)
api_app.enable_csrf_protection!

web_app = Otto.new('web/routes')
web_app.add_auth_strategy('session', SessionStrategy.new)
web_app.enable_csrf_protection!

admin_app = Otto.new('admin/routes')
admin_app.add_auth_strategy('role', AdminRoleStrategy.new)

# Mount at different paths
map = Rack::URLMap.new(
  '/api'   => api_app,
  '/admin' => admin_app,
  '/'      => web_app
)

run map
```

**Important**: Each Otto instance has:
- Isolated configuration (freezes independently)
- Isolated callbacks (on_request_complete fires per-instance)
- Isolated middleware stack

---

## Monitoring and Debugging

### Request Timing and Metrics

Track request performance across your application:

```ruby
class MetricsController
  @@request_times = []

  def self.add_request_metric(duration_μs)
    @@request_times << duration_μs
  end

  def stats
    times = @@request_times
    avg = times.sum / times.length
    min = times.min
    max = times.max
    p95 = times.sort[times.length * 95 / 100]

    @res.body = JSON.generate({
      average_μs: avg,
      min_μs: min,
      max_μs: max,
      p95_μs: p95,
      total_requests: times.length
    })
  end
end

# In config.ru
otto = Otto.new(routes)
otto.on_request_complete do |req, res, duration_μs|
  MetricsController.add_request_metric(duration_μs)
end
```

### Error Tracking Integration

Integrate with error tracking services:

```ruby
require 'sentry-ruby'

Sentry.init do |config|
  config.dsn = ENV['SENTRY_DSN']
  config.environment = ENV['RACK_ENV']
end

otto = Otto.new(routes)

# Catch errors and send to Sentry
otto.on_error do |error, env, error_id|
  Sentry.capture_exception(error, {
    tags: { error_id: error_id },
    extra: {
      request_path: env['PATH_INFO'],
      request_method: env['REQUEST_METHOD'],
      remote_ip: env['REMOTE_ADDR']
    }
  })
end
```

---

## Testing

### Test Routes and Handlers

```ruby
require 'minitest/autorun'
require 'otto'
require './app'

class UserControllerTest < Minitest::Test
  def setup
    @otto = Otto.new(File.expand_path('../../routes', __FILE__))
  end

  def test_list_users
    env = Rack::MockRequest.env_for('/users')
    status, headers, body = @otto.call(env)

    assert_equal 200, status
    data = JSON.parse(body.join)
    assert_kind_of Array, data
  end

  def test_create_user
    env = Rack::MockRequest.env_for(
      '/users',
      method: 'POST',
      params: { name: 'Alice', email: 'alice@example.com' }
    )

    status, headers, body = @otto.call(env)

    assert_equal 201, status
    data = JSON.parse(body.join)
    assert data['id']
  end
end
```

### Test Authentication

```ruby
def test_protected_route_requires_auth
  env = Rack::MockRequest.env_for('/admin', params: {})
  status, _, _ = @otto.call(env)

  assert_equal 401, status  # Unauthorized
end

def test_protected_route_with_valid_token
  env = Rack::MockRequest.env_for('/admin', params: { token: 'valid_token' })
  status, _, body = @otto.call(env)

  assert_equal 200, status
  assert_includes body.join, 'Admin Dashboard'
end
```

---

## Deployment Checklist

Before deploying to production:

- [ ] All security features enabled (`enable_csrf_protection!`, etc.)
- [ ] IP privacy configured appropriately (`configure_ip_privacy` or `disable_ip_privacy`)
- [ ] All auth strategies registered
- [ ] All trusted proxies configured
- [ ] Error handlers registered for expected business errors
- [ ] Logging configured and monitored
- [ ] Database connections configured
- [ ] Environment variables set correctly
- [ ] SSL/HTTPS configured in reverse proxy
- [ ] Rate limiting configured
- [ ] File upload validation in place
- [ ] Input validation on all user-facing routes
- [ ] Secrets stored in environment variables, not hardcoded
- [ ] Tests passing
- [ ] Load testing done
- [ ] Monitoring and alerting configured

---

## Key Principles

1. **Security by Default**: Enable security features, don't add them later
2. **Explicit Over Implicit**: Be clear about what each route does (auth, response type, etc.)
3. **Structured Logging**: Log request context consistently for debugging
4. **Fail Fast**: Validate input early and raise errors immediately
5. **Cache Strategically**: Cache expensive operations, not everything
6. **Test Thoroughly**: Test routes, authentication, and error cases
7. **Monitor Continuously**: Track performance and errors in production
8. **Document Clearly**: Comment complex logic and document configuration

---

## Further Reading

- [Architecture Guide](architecture.md) - How Otto works internally
- [Troubleshooting Guide](troubleshooting.md) - Common issues and solutions
- [CLAUDE.md](../CLAUDE.md) - Comprehensive reference documentation
- [examples/security_features/](../examples/security_features/) - Security implementation examples
- [examples/authentication_strategies/](../examples/authentication_strategies/) - Auth patterns
