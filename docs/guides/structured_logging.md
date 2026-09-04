# Structured Logging Documentation

Otto uses simple, explicit structured logging with timing capabilities. Avoid creating abstraction layers or event classes.

## LoggingHelpers Module

Otto provides several helper methods for consistent logging:

```ruby
# Request context extraction
Otto::LoggingHelpers.request_context(env)
# Returns: { method:, path:, ip:, country:, user_agent: }

# Timed operation logging
Otto::LoggingHelpers.log_timed_operation(level, message, env, **metadata) { block }
```

## Logging Patterns

Use `Otto.structured_log` with `LoggingHelpers.request_context(env).merge()` for all structured logging:

**Thread Safety Note**: The base context pattern is thread-safe for concurrent requests. Each request has its own `env` hash, so `request_context(env)` creates isolated context hashes per request. The pattern extracts immutable values (strings, symbols) from `env`, and the `.merge()` creates a new hash rather than mutating shared state. This makes it safe for use in multi-threaded Rack servers (Puma, Falcon, etc.).

```ruby
# Route logging
Otto.structured_log(:debug, "Route matched",
  Otto::LoggingHelpers.request_context(env).merge(
    type: 'literal',
    handler: route.route_definition.definition,
    auth_strategy: route.route_definition.auth_requirement || 'none'
  )
)

# Authentication logging
Otto.structured_log(:info, "Auth strategy result",
  Otto::LoggingHelpers.request_context(env).merge(
    strategy: strategy.class.name.split('::').last.downcase.gsub('strategy', ''),
    success: true,
    user_id: result.user_id,
    duration: duration_μs
  )
)
```

For operations that need timing, use `log_timed_operation` which wraps `structured_log` with automatic timing:

```ruby
# Template compilation with timing
result = Otto::LoggingHelpers.log_timed_operation(:info, "Template compiled", env,
  template_type: 'handlebars',
  cached: false
) do
  compile_template(template_path)
end

# Database operation with timing
Otto::LoggingHelpers.log_timed_operation(:debug, "User lookup", env,
  user_id: user_id,
  cache_hit: false
) do
  User.find(user_id)
end
```

## Timing Conventions

Otto uses **microseconds** for all timing measurements via `Otto::Utils.now_in_μs`:

```ruby
# Manual timing
start_time = Otto::Utils.now_in_μs
result = perform_operation()
duration = Otto::Utils.now_in_μs - start_time

Otto.structured_log(:info, "Operation completed",
  Otto::LoggingHelpers.request_context(env).merge(
    operation: 'user_creation',
    duration: duration  # Always in microseconds
  )
)

# Automatic timing with error handling
Otto::LoggingHelpers.log_timed_operation(:info, "Database query", env,
  table: 'users',
  query_type: 'SELECT'
) do
  database.execute(query)
end
```

## Required Fields

All structured logs should include:
- **method** - HTTP method (GET, POST, etc.)
- **path** - Request path
- **ip** - Client IP (automatically masked by IPPrivacyMiddleware for public IPs)
- **duration** - Operation timing in microseconds (for timed operations)
- **Event-specific data** - Handler, type, error message, etc.

## Optional Fields

Include when relevant:
- **country** - Geo-location country code (from IPPrivacyMiddleware)
- **user_agent** - Browser/client info (truncated to 100 chars)
- **user_id** - Authenticated user ID
- **referrer** - HTTP Referer header
- **error** - Error message
- **error_class** - Error class name (for exceptions)

## Error Handling in Timed Operations

`log_timed_operation` automatically handles exceptions:

```ruby
# Successful operation
Otto::LoggingHelpers.log_timed_operation(:info, "Template compiled", env, template: 'user') do
  compile_template('user')
end
# Logs: Template compiled: method=GET path=/users template=user duration=15230

# Failed operation (automatic error logging + re-raise)
Otto::LoggingHelpers.log_timed_operation(:info, "Template compiled", env, template: 'user') do
  raise StandardError, "Template not found"
end
# Logs: Template compiled failed: method=GET path=/users template=user duration=1520 error="Template not found" error_class=StandardError
# Then re-raises the original exception
```

## Privacy Awareness

- IP addresses in logs are **already masked** by `IPPrivacyMiddleware` (public IPs only)
- Private IPs (127.0.0.1, 192.168.x.x, 10.x.x.x) are **never masked**
- `env['REMOTE_ADDR']` contains masked IP for public addresses
- User agents are automatically truncated to prevent log bloat

## Backtrace Sanitization (Security by Default)

Otto automatically sanitizes exception backtraces to prevent exposing sensitive system information in logs. This is critical for both security and compliance.

**Security Risks of Raw Backtraces:**
- Expose absolute paths revealing usernames (`/Users/alice/`, `/home/admin/`)
- Reveal project structure and internal organization
- Show gem installation paths and Ruby versions
- Leak system architecture details

**Automatic Sanitization in Otto.structured_log:**

Otto automatically sanitizes backtraces in `Otto.structured_log` when a `:backtrace` key contains an Array.

**Sanitization Rules:**

```ruby
# Project files → relative paths only
"/Users/alice/myapp/app/controllers/users_controller.rb:42:in `create'"
# ↓ SANITIZED TO:
"app/controllers/users_controller.rb:42:in `create'"

# Bundler gems → [GEM] tag with gem name only
"/Users/alice/.rbenv/versions/3.4.7/lib/ruby/gems/3.4.0/bundler/gems/otto-34f285412a44/lib/otto/route.rb:142"
# ↓ SANITIZED TO:
"[GEM] otto/lib/otto/route.rb:142"

# Regular gems → [GEM] tag, version stripped
"/opt/ruby/gems/3.4.0/gems/rack-3.2.4/lib/rack/builder.rb:310"
# ↓ SANITIZED TO:
"[GEM] rack/lib/rack/builder.rb:310"

# Ruby stdlib → [RUBY] tag with filename only
"/Users/alice/.rbenv/versions/3.4.7/lib/ruby/3.4.0/logger.rb:310"
# ↓ SANITIZED TO:
"[RUBY] logger.rb:310"

# Unknown/external → filename only
"/some/unknown/path/file.rb:50"
# ↓ SANITIZED TO:
"[EXTERNAL] file.rb:50"
```

**Usage:**

Sanitization happens automatically when using `log_backtrace`:

```ruby
# In error handlers (Otto does this automatically)
Otto::LoggingHelpers.log_backtrace(error,
  Otto::LoggingHelpers.request_context(env).merge(
    error_id: error_id,
    handler: 'UserController#create'
  )
)

# Manual usage if needed
sanitized = Otto::LoggingHelpers.sanitize_backtrace(error.backtrace)
```

## Anti-Patterns

**❌ Don't create event classes:**
```ruby
# NO - Adds unnecessary abstraction
event = RouteMatchEvent.new(type: :literal, method: http_verb, path: path)
Otto.structured_log(event.level, event.message, event.to_h)
```

**❌ Don't create helper wrappers:**
```ruby
# NO - Hides what's being logged
Otto::Logging.log_route_match(type: :literal, method: http_verb, path: path, env: env)
```

**❌ Don't mix timing units:**
```ruby
# NO - Inconsistent units
duration_ms = (Otto::Utils.now_in_μs - start_time) / 1000  # Converting to milliseconds
Otto.structured_log(:info, "Operation done", { duration_ms: duration_ms })
```

**✅ Do use explicit inline logging:**
```ruby
# YES - Clear, simple, explicit
Otto.structured_log(:debug, "Route matched",
  Otto::LoggingHelpers.request_context(env).merge(
    type: 'literal',
    handler: 'App#index'
  )
)

# YES - Consistent microsecond timing
Otto.structured_log(:info, "Operation completed",
  Otto::LoggingHelpers.request_context(env).merge(
    operation: 'user_lookup',
    duration: Otto::Utils.now_in_μs - start_time
  )
)
```

## Output Examples

**Example Output (with SemanticLogger or similar structured logger):**
```
I, [2025-01-21T14:39:39.462833 #82244] INFO -- : Template compiled -- {method: "GET", path: "/users", ip: "192.0.2.0", template_type: "handlebars", cached: false, duration: 68}
I, [2025-01-21T14:39:39.462926 #82244] INFO -- : View rendered -- {method: "GET", path: "/users", ip: "192.0.2.0", template: "user_profile", layout: "application", partials: ["header", "sidebar"], duration: 1118, response_size_bytes: 2048}
```

## Rationale

- **Simplicity**: Direct logging calls are easier to understand than abstraction layers
- **Explicitness**: You can see exactly what's being logged at the call site
- **Flexibility**: Easy to add one-off fields without modifying event classes
- **Performance**: No object allocation overhead for disabled debug logs
- **Consistency**: All timing in microseconds, automatic error handling for timed operations
- **Maintainability**: One helper file vs multiple event classes/helpers
