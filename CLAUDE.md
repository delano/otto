# CLAUDE.md

This file provides essential guidance to Claude Code when working with Otto.

## Error Handler Registration

Register handlers for expected business logic errors to avoid logging them as 500 errors:

```ruby
otto = Otto.new('routes.txt')
otto.register_error_handler(YourApp::NotFound, status: 404, log_level: :info)
otto.register_error_handler(YourApp::RateLimited, status: 429, log_level: :warn)
```

Must be registered before first request (before configuration freezing).

## Request/Response Helper Registration

Register application helpers that integrate with Otto features (authentication, privacy, locale):

```ruby
module YourApp::RequestHelpers
  def current_customer
    user = strategy_result&.user
    user.is_a?(YourApp::Customer) ? user : YourApp::Customer.anonymous
  end
end

otto = Otto.new('routes.txt')
otto.register_request_helpers(YourApp::RequestHelpers)
otto.register_response_helpers(YourApp::ResponseHelpers)
```

Must be registered before first request. Helpers available in routes, middleware, and error handlers.

### Reserved Method Names

Helper modules should avoid overriding these methods inherited from Rack::Request/Rack::Response:

**Request reserved methods**: `env`, `params`, `cookies`, `session`, `path`, `path_info`, `query_string`, `request_method`, `content_type`, `content_length`, `media_type`, `get?`, `post?`, `put?`, `delete?`, `head?`, `options?`, `patch?`, `xhr?`, `referer`, `user_agent`, `base_url`, `url`, `fullpath`, `ip`, `host`, `port`, `ssl?`, `scheme`

**Response reserved methods**: `status`, `headers`, `body`, `finish`, `write`, `close`, `set_cookie`, `delete_cookie`, `redirect`, `content_type`, `content_length`, `location`

**Otto-specific methods**: `request` (on Response), `app_path`, `masked_ip`, `hashed_ip`, `client_ipaddress`, `secure?`, `local?`, `ajax?`

No runtime validation is performed for performance reasons. Overriding these methods will cause undefined behavior.

## Authentication Architecture

Authentication is handled by `RouteAuthWrapper` at the handler level, NOT by middleware.

### Basic Configuration

```ruby
otto.add_auth_strategy('session', SessionStrategy.new)
otto.add_auth_strategy('apikey', APIKeyStrategy.new)
```

- Strategy names must be unique
- Routes with `auth` requirements are automatically wrapped
- Must be configured before first request

### Multi-Strategy Authentication

Routes support multiple strategies with OR logic:

```ruby
# Routes file
GET /api/data  DataLogic#show  auth=session,apikey,oauth
```

- Strategies execute left-to-right
- First success wins (remaining strategies skipped)
- Returns 401 only if all strategies fail
- Put fastest/most-common strategies first

### Two-Layer Authorization

**Layer 1: Route-Level (RouteAuthWrapper)**
- Use `auth=` for authentication strategies
- Use `role=` for role-based access (OR logic: `role=admin,editor`)
- Fast execution (no database queries)
- Returns 401 (authentication) or 403 (authorization)

**Layer 2: Resource-Level (Logic classes)**
- Handled in `raise_concerns` method
- Checks ownership, relationships, resource attributes
- Raises `Otto::Security::AuthorizationError` for 403 response

```ruby
# Route-level
GET /admin/users  AdminLogic  auth=session role=admin

# Resource-level in Logic class
def raise_concerns
  @post = Post.find(params[:id])
  unless @post.user_id == @context.user_id
    raise Otto::Security::AuthorizationError, "Cannot edit another user's post"
  end
end
```

## Configuration Freezing

Otto automatically freezes all configuration after first request to prevent runtime security bypasses. Multi-step initialization must complete before first request.

## IP Privacy (Privacy by Default)

Otto automatically masks public IP addresses while preserving private/localhost IPs for development:

- `IPPrivacyMiddleware` runs FIRST in middleware stack
- Replaces `env` values directly (REMOTE_ADDR, HTTP_USER_AGENT, HTTP_REFERER)
- Public IPs masked (192.0.2.100 → 192.0.2.0)
- Private IPs never masked (127.0.0.1, 192.168.x.x, 10.x.x.x)
- Supports proxy resolution with trusted proxy configuration

For multi-app architectures, add to common middleware stack before logging/monitoring.

## Structured Logging

Use explicit structured logging with timing:

```ruby
Otto.structured_log(:debug, "Route matched",
  Otto::LoggingHelpers.request_context(env).merge(
    type: 'literal',
    handler: route.definition
  )
)

# For timed operations
Otto::LoggingHelpers.log_timed_operation(:info, "Operation", env, key: value) do
  perform_operation()
end
```

- All timing in microseconds via `Otto::Utils.now_in_μs`
- Use `request_context(env).merge()` pattern for consistency
- Avoid abstraction layers or event classes

## Development Commands

```bash
bundle install
bundle exec rubocop
bundle exec rspec
```

## Key Architecture Principles

- **Security by Default**: IP privacy, configuration freezing, backtrace sanitization
- **Privacy by Default**: Public IP masking, no original value storage
- **Explicit over Implicit**: Direct logging calls, clear configuration
- **Handler-Level Auth**: Not middleware-based authentication
- **Two-Layer Authorization**: Route-level + resource-level separation
- **Rack Integration**: Standard Rack patterns and compatibility

See `docs/` directory for comprehensive documentation.
