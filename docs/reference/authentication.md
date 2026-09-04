# Authentication Architecture Documentation

Otto implements authentication at the handler level via `RouteAuthWrapper`, NOT through middleware. This provides precise control over authentication requirements per route.

## Basic Configuration

Authentication strategies are configured during Otto initialization:

```ruby
otto = Otto.new('routes.txt')
otto.add_auth_strategy('session', SessionStrategy.new)
otto.add_auth_strategy('apikey', APIKeyStrategy.new(api_keys: ENV.fetch('API_KEYS').split(',')))
otto.add_auth_strategy('oauth', OAuthStrategy.new)
```

**Key Rules:**
- Strategy names must be unique (duplicate registration raises ArgumentError)
- Must be registered before first request (configuration freezing)
- Routes with `auth` requirements are automatically wrapped by RouteAuthWrapper

## Multi-Strategy Authentication (OR Logic)

Routes can specify multiple authentication strategies with comma-separated syntax:

```ruby
# Routes file
GET /api/data  DataLogic#show  auth=session,apikey,oauth
```

**Execution Flow:**
1. Strategies execute left-to-right in order
2. **First success wins** - remaining strategies are not executed
3. Returns 401 only if **all** strategies fail
4. Unknown strategies cause immediate 401 (strict mode)

**Performance Tip:** Put fastest/most-common strategies first (e.g., `auth=session,apikey`)

**Example Execution:**
```ruby
# Route: auth=session,apikey,oauth
# 1. Tries 'session' strategy
# 2. If session succeeds → call handler (apikey/oauth not executed)
# 3. If session fails → try 'apikey' strategy
# 4. If apikey succeeds → call handler (oauth not executed)
# 5. If apikey fails → try 'oauth' strategy
# 6. If oauth succeeds → call handler
# 7. If all fail → return 401
```

## Strategy Pattern Matching

- **Exact match**: `'authenticated'` → looks up `auth_config[:auth_strategies]['authenticated']`
- **Prefix match**: `'custom:value'` → looks up `'custom'` strategy and passes full requirement
- **Results are cached** per wrapper instance

## Two-Layer Authorization Pattern

Otto implements industry-standard separation between authentication and authorization:

### Layer 1: Route-Level Authorization

Handled by `RouteAuthWrapper` before handler execution:

```ruby
# Routes file examples
GET /admin/users     AdminUserLogic       auth=session role=admin
GET /content/edit    ContentEditLogic     auth=session role=admin,editor
GET /profile         ProfileLogic         auth=session
```

**Features:**
- Use `auth=` for authentication strategies
- Use `role=` for role-based route access (OR logic for multiple roles)
- Fast execution (no database queries)
- Returns 401 (Unauthorized) for authentication failures
- Returns 403 (Forbidden) for authorization failures

**Role Extraction Order:**
1. `result.user_roles` (direct accessor)
2. `result.user[:roles]` (user hash with symbol key)
3. `result.user['roles']` (user hash with string key)
4. `result.metadata[:user_roles]` (metadata)

### Layer 2: Resource-Level Authorization

Handled by Logic classes in `raise_concerns` method:

```ruby
# Route: GET /posts/:id/edit  PostEditLogic  auth=session
class PostEditLogic
  def raise_concerns
    @post = Post.find(params[:id])

    # Resource-level authorization
    unless @post.user_id == @context.user_id
      raise Otto::Security::AuthorizationError, "Cannot edit another user's post"
    end
  end

  def process
    # Edit post logic
  end
end
```

**Features:**
- Checks ownership, relationships, resource attributes
- Requires database queries to load resources
- Raises `Otto::Security::AuthorizationError` for 403 response
- Auto-registered during Otto initialization (logged at WARN level)

## Strategy Implementation Examples

### Session Strategy with Roles

```ruby
class RoleAwareSessionStrategy < Otto::Security::Authentication::AuthStrategy
  def authenticate(env, _requirement)
    session = env['rack.session']
    return failure('No session') unless session

    user_id = session['user_id']
    # A session cookie is an ambient credential: leave this non-terminal so a
    # later strategy in an OR chain can still run.
    return failure('Not authenticated') unless user_id

    # Include roles in the user data
    success(
      user: {
        id: user_id,
        roles: session['user_roles'] || []  # Accessible as user[:roles]
      },
      session: session
    )
  end
end
```

Strategies do not choose a redirect. `RouteAuthWrapper` turns a `failure` into
a 401 for API clients and, for HTML requests, a 302 to
`otto.auth_config[:login_path]` (default `/signin`).

### API Key Strategy

Otto ships `Otto::Security::Authentication::Strategies::APIKeyStrategy`; see
that class for the real implementation. It reads the `X-API-Key` header only
unless you pass `param_name: 'api_key'` to also accept the credential as a query
or form parameter — keys in URLs are recorded by access logs, proxies, and
browser history. Its result carries `user[:api_key_fingerprint]` (a truncated
SHA-256 digest), never the key itself. A custom key-backed strategy follows the
same shape:

```ruby
class DatabaseAPIKeyStrategy < Otto::Security::Authentication::AuthStrategy
  def authenticate(env, _requirement)
    api_key = env['HTTP_X_API_KEY'] || extract_from_params(env)
    # No credential presented: non-terminal, so a later strategy may still run.
    return failure('Missing API key') if api_key.nil? || api_key.empty?

    user = User.find_by_api_key(api_key)
    # A credential WAS presented and rejected: terminal, fail closed with 401.
    return failure('Invalid API key', terminal: true) unless user

    success(user: { id: user.id, roles: user.roles }, auth_method: 'api_key')
  end

  private

  def extract_from_params(env)
    Otto::Request.new(env).params['api_key']
  end
end
```

`success`, `failure`, and `authorization_failure` are protected helpers on
`AuthStrategy`; `failure` maps to 401 (or the login redirect above, for HTML
requests) and `authorization_failure` to 403.

## Complex Authorization Example

```ruby
class OrganizationDeleteLogic
  def raise_concerns
    @org = Organization.find(params[:id])

    # Complex authorization: admin role OR ownership
    has_permission = @context.user_roles.include?('admin') ||
                     @org.owner_id == @context.user_id

    unless has_permission
      raise Otto::Security::AuthorizationError,
        "Requires admin role or organization ownership",
        resource: 'Organization',
        action: 'delete',
        user_id: @context.user_id
    end
  end
end
```

## AuthorizationError Features

- Auto-registered during Otto initialization (returns 403)
- Logged at WARN level (not ERROR)
- Optional context: `resource`, `action`, `user_id` for debugging
- Supports structured logging via `to_log_data`

## RouteAuthWrapper Flow

When a route has authentication requirements:

1. Looks up strategies from `auth_config[:auth_strategies]`
2. Executes `strategy.authenticate(env, requirement)` for each strategy
3. On first success:
   - Sets `env['rack.session']` (if provided)
   - Sets `env['otto.strategy_result']`
   - Sets `env['otto.user']` (extracted from result)
   - Checks role requirements (if `role=` specified)
   - Calls wrapped handler
4. If all strategies fail: Returns 401/302
5. If role check fails: Returns 403

## Compatibility Notes

- `enable_authentication!` is a no-op kept for API compatibility
- AuthenticationMiddleware was removed (architecturally broken - ran before routing)
- `auth=role:admin` syntax removed in favor of separate `role=admin` option

## Best Practices

1. **Use Layer 1 for broad access control** (admin-only sections)
2. **Use Layer 2 for resource-specific authorization** (ownership, relationships)
3. **Put fastest strategies first** in multi-strategy auth
4. **Include roles in StrategyResult.user** for route-level authorization
5. **Use structured logging** for authorization failures
6. **Register all strategies before first request** (configuration freezing)
