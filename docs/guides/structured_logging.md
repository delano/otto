# Structured logging

Otto provides explicit logging helpers for request context, microsecond timing,
and backtrace path reduction. The helpers do not sanitize arbitrary metadata;
callers remain responsible for excluding secrets and personal data.

## Logging helpers

Otto provides several helper methods for consistent logging:

```ruby
# Request context extraction
Otto::LoggingHelpers.request_context(env)
# May include: { method:, path:, ip:, country:, user_agent: }

# Timed operation logging
Otto::LoggingHelpers.log_timed_operation(level, message, env, **metadata) { block }
```

## Logging patterns

For request-scoped structured logging, use `Otto.structured_log` with
`LoggingHelpers.request_context(env).merge()`:

`request_context(env)` creates a new context hash, and `.merge` creates another
hash rather than mutating shared state. Treat the request `env` and values inside
it as request-owned data; the helper does not deep-copy mutable strings.

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

## Timing conventions

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

## Request fields

Request-scoped events should normally merge `request_context(env)`, which adds
available values for:

- **method** - HTTP method (`GET`, `POST`, etc.)
- **path** - request path
- **ip** - canonical client IP under the configured privacy profile
- **country** - resolved country when available
- **user_agent** - current request user agent, truncated to 100 characters

Unavailable values are omitted. Non-request events, such as configuration or
startup logs, should include only relevant event-specific fields. Timed events
also include **duration** in microseconds.

Additional fields such as `user_id`, `handler`, `error`, or `error_class` may be
useful, but Otto does not redact them. Do not log credentials, session tokens,
raw request parameters, or exception messages that may contain secrets.

## Error handling in timed operations

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

## Privacy behavior

`request_context` prefers `env['otto.client_ip']`, the canonical value produced
by `IPPrivacyMiddleware`:

- Under the normal privacy profiles, public addresses are masked.
- Under the `:audit` profile or after `disable_ip_privacy!`, the canonical public
  address is raw and `request_context` logs it unchanged.
- Private and localhost addresses remain raw under the default `:masked` profile;
  the `:anonymous` profile masks them too.
- Outside Otto's middleware, when `otto.client_ip` is absent,
  `privacy_safe_ip` masks a public `REMOTE_ADDR` using the default precision and
  returns `[redacted]` for an unparseable address.
- `request_context` truncates the current `HTTP_USER_AGENT` to 100 characters.
  It is anonymized only if the privacy middleware has already anonymized it.

The helper does not make arbitrary metadata privacy-safe. Review every field
added by the caller.

## Backtrace path reduction

Otto reduces filesystem details in recognized Ruby backtrace lines. This is
defense in depth, not a confidentiality boundary: custom or unrecognized lines
are returned unchanged.

**Risks of raw backtraces:**
- Expose absolute paths revealing usernames (`/Users/alice/`, `/home/admin/`)
- Reveal project structure and internal organization
- Show gem installation paths and Ruby versions
- Leak system architecture details

**Automatic path reduction in `Otto.structured_log`:**

`Otto.structured_log` applies the backtrace sanitizer only when the metadata is
a hash whose exact `:backtrace` key contains an array. Other fields and arrays
are passed unchanged.

**Path-reduction rules:**

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

Path reduction happens automatically when using `log_backtrace`. This helper
logs at `:error` and limits the backtrace to its first 20 lines:

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

## Anti-patterns

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

## Output behavior

`Otto.logger` defaults to Ruby's `Logger`. With that logger, metadata is rendered
inside a formatted string:

```text
I, [2025-01-21T14:39:39.462833 #82244] INFO -- : [Otto] Template compiled -- {method: "GET", path: "/users", ip: "192.0.2.0", template_type: "handlebars", cached: false, duration: 68}
```

For a logger whose level method has a fixed arity greater than one, Otto calls
that method as `logger.info(message, metadata)`. Other logger APIs use the
formatted-string fallback. Verify the adapter for a third-party structured
logger before relying on separately indexed fields; Otto does not ship or test
a SemanticLogger adapter.

## Rationale

- **Simplicity**: Direct logging calls are easier to understand than abstraction layers
- **Explicitness**: You can see exactly what's being logged at the call site
- **Flexibility**: Easy to add one-off fields without modifying event classes
- **Performance**: Disabled debug events are not sent to the logger; guard expensive metadata construction with `if Otto.debug` because method arguments are evaluated first
- **Consistency**: All timing in microseconds, automatic error handling for timed operations
- **Maintainability**: One helper file vs multiple event classes/helpers
