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
1. Unknown strategy names fail the request with 401 before any strategy runs
   (strict mode)
2. Strategies execute left-to-right in order
3. The first **authenticated** success (a result with a user) wins; the
   remaining strategies are not executed
4. An **anonymous** success (a result without a user, e.g. from `noauth`)
   does not win yet. It is held as a fallback and the chain continues; only
   the first anonymous success is held
5. A plain failure is recorded and the next strategy runs
6. A terminal failure (`AuthFailure` with `terminal: true`, e.g. an API key
   that was presented and rejected) halts the chain, and a held anonymous
   fallback does not rescue the request
7. If the chain completes without an authenticated success or a terminal
   failure, the held anonymous fallback wins
8. Otherwise the request fails: 403 if any strategy returned an
   `AuthorizationFailure`, else 401 when the route is `response=json` or the
   request accepts `application/json`, and a 302 redirect to the login path
   for other requests

**Performance Tip:** Put fastest/most-common strategies first (e.g., `auth=session,apikey`)

**Example Execution:**
```ruby
# Route: auth=session,apikey,oauth
# 1. Tries 'session' strategy
# 2. If session authenticates → call handler (apikey/oauth not executed)
# 3. If session fails → try 'apikey' strategy
# 4. If apikey authenticates → call handler (oauth not executed)
# 5. If apikey fails → try 'oauth' strategy
# 6. If oauth authenticates → call handler
# 7. If all fail → 401, 403 or 302 (Execution Flow, step 8)
```

Declaration order does not let an anonymous strategy win early. On
`auth=noauth,session`, a request whose session holds a user is
authenticated by `session`, and `noauth` wins only when `session` fails. On
`auth=noauth,apikey`, a request that presents an invalid API key is refused:
the key's terminal failure halts the chain, and the response follows step 8
(401 when the route is `response=json` or the request accepts
`application/json`, otherwise a 302 redirect to the login path).

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
- Returns 401 (Unauthorized) for authentication failures, or a 302 redirect to
  the login path for requests that do not want JSON
- Returns 403 (Forbidden) for authorization failures

**Role Extraction Order** (checked in order; the first source that is set is
used):
1. `result.user_roles`, if the result responds to it (`StrategyResult` does
   not define it)
2. For a Hash user: `result.user[:roles]`, then `result.user['roles']`. A set
   value is used even when it is empty
3. For any other user object (ORM model, PORO, `Data`/`Struct`):
   `result.user.roles`, stringified; if the user does not respond to `#roles`
   or it yields no roles, `result.user.role`
4. `result.metadata[:user_roles]` (metadata; `RoleStrategy` puts the session's
   roles here)

A user object that is not a Hash and responds to neither `#roles` nor `#role`
contributes no roles instead of raising `NoMethodError`; the metadata source
is still checked.

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
or form parameter; keys in URLs are recorded by access logs, proxies, and
browser history. The strategy never places the raw key in the result; its own
field is `metadata[:api_key_fingerprint]` (a truncated SHA-256 digest). With a
static `api_keys:` list `user` is a Hash carrying the same fingerprint, and
with a resolver `user` is whatever the resolver returned, verbatim.

Keys come from exactly one of three sources. `api_keys:` takes a static list
and matches under constant-time comparison. A block, or a `resolver:` that
responds to `#call`, looks the presented key up and returns the account behind
it:

```ruby
APIKeyStrategy = Otto::Security::Authentication::Strategies::APIKeyStrategy

# Static list
APIKeyStrategy.new(api_keys: ENV.fetch('API_KEYS').split(','))

# Block resolver, looking up by digest so raw keys never touch the database
APIKeyStrategy.new do |presented_key|
  ApiKey.find_by(digest: APIKeyStrategy.digest(presented_key))&.account
end

# Callable resolver
APIKeyStrategy.new(resolver: repo.method(:find_by_key))
```

Passing none of the three, or more than one, raises `ArgumentError`. The
resolver receives only the presented key as a non-empty `String`; a missing
credential is still the non-terminal `No API key provided` failure and never
reaches the resolver. A `nil` or `false` return is the terminal
`Invalid API key` failure (401), the same as a static mismatch; any other
value, including an empty relation, Array, or Hash, is a match, so return one
record or `nil`, not a `where(...)` relation. Exceptions from
the resolver propagate rather than turning into a 401 or a success. The
returned value becomes `user`, and `api_key_fingerprint` is set in the metadata
regardless. The result is stored in `env['otto.strategy_result']` and exposed
to handlers, so anything the application serializes or logs from it carries
`user`; the resolver must not return an object that carries the raw key:
return the account, not the `ApiKey` row that stores the key, and store
digests. Returning the presented key string itself as the user raises
`ArgumentError`. `APIKeyStrategy.digest(key)` is the full SHA-256 hex digest;
the fingerprint is its first 12 characters.

The strategy cannot make a black-box lookup constant-time. Store SHA-256
digests and look up by `APIKeyStrategy.digest(presented_key)`, as above.

`APIKeyStrategy` is a small static-allowlist authenticator shipped as a
low-dependency convenience and reference implementation. It has no native
support for runtime addition or revocation, expiration, per-client roles or
scopes, ownership or descriptive metadata, usage quotas, a management API,
persisted audit history, or hashed verifier storage. The resolver form hands
validity, roles, and metadata to the application's key store; the rest stay
outside the strategy. See the
[authentication guide](../guides/authentication.md#what-apikeystrategy-does-not-provide).

A custom key-backed strategy that needs more than the resolver offers (for
example, consulting `env`) follows the same shape:

```ruby
class DatabaseAPIKeyStrategy < Otto::Security::Authentication::AuthStrategy
  def authenticate(env, _requirement)
    api_key = env['HTTP_X_API_KEY'] || extract_from_params(env)
    # No credential presented: non-terminal, so a later strategy may still run.
    return failure('Missing API key') if api_key.nil? || api_key.empty?

    digest = Otto::Security::Authentication::Strategies::APIKeyStrategy.digest(api_key)
    user = User.find_by(api_key_digest: digest)
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
2. Executes `strategy.authenticate(env, requirement)` for each strategy in
   order, until one authenticates or a terminal failure halts the chain
3. On the winning success (the first authenticated success, or the held
   anonymous fallback once the chain completes; see Execution Flow above):
   - Sets `env['rack.session']` to `result.session` (unless that is `nil` or
     `false`) when env holds no session a middleware installed: the key is
     absent, or it holds the `Otto::Request::DefaultSession` that
     `Otto::Request#session` installs when no session middleware ran. A
     session a middleware installed is never replaced
   - Sets `env['otto.strategy_result']`; the user is
     `env['otto.strategy_result'].user`
   - Checks role requirements (if `role=` specified)
   - Calls wrapped handler
4. If the chain fails (every strategy failed, or a terminal failure halted
   it): Returns 403, 401 or 302, as in Execution Flow step 8
5. If role check fails: Returns 403

## Compatibility Notes

- `enable_authentication!` was removed; calling it raises `NoMethodError`.
  `RouteAuthWrapper` wraps every route handler without it
- AuthenticationMiddleware was removed (architecturally broken - ran before routing)
- `env['otto.user']` is not set; read the user from
  `env['otto.strategy_result'].user`
- `auth=role:admin` is a strategy requirement, not the route-level role check.
  It resolves to a strategy registered under the exact name `role:admin`, or
  else to the one registered as `role` (prefix match). A `RoleStrategy`
  checks `admin` against the session's roles (`user_roles` by default).
  `role=admin` is the separate route-level check (Layer 1) against the
  successful strategy result

## Best Practices

1. **Use Layer 1 for broad access control** (admin-only sections)
2. **Use Layer 2 for resource-specific authorization** (ownership, relationships)
3. **Put fastest strategies first** in multi-strategy auth
4. **Include roles in StrategyResult.user** for route-level authorization
5. **Use structured logging** for authorization failures
6. **Register all strategies before first request** (configuration freezing)
