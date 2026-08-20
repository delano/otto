# Authentication and authorization

Otto authenticates at the route handler boundary. Authentication is not a
middleware that runs before routing; only routes with `auth=` requirements are
wrapped. This lets a route declare its access requirement next to its HTTP
contract.

Authentication answers **who is this request from?** Authorization answers
**may that subject perform this action?** Keep those questions separate.

## Register strategies before the first request

Register named strategy instances during boot:

```ruby
otto = Otto.new('routes')
otto.add_auth_strategy(
  'session',
  Otto::Security::Authentication::Strategies::SessionStrategy.new(
    session_key: 'user_id'
  )
)
otto.add_auth_strategy(
  'api_key',
  Otto::Security::Authentication::Strategies::APIKeyStrategy.new(
    api_keys: ENV.fetch('API_KEYS', '').split(',')
  )
)
```

A strategy implements `authenticate(env, requirement)` and returns a
`StrategyResult`, `AuthFailure`, or `AuthorizationFailure`. Subclass
`Otto::Security::Authentication::AuthStrategy` to use its `success`, `failure`,
and `authorization_failure` helpers.

Strategy names must be unique. Registration and other security configuration
must happen before the first request, when Otto freezes configuration.

## Protect a route

Put the strategy name in the route file:

```text
GET /profile    Profile#show auth=session
GET /api/data   Api::Data response=json auth=api_key
```

The strategy receives the full requirement string. Exact names resolve directly;
colon-qualified requirements such as `oauth:google` first try an exact match,
then fall back to the registered `oauth` strategy while preserving the full
requirement for that strategy.

A route without `auth=` receives an anonymous `StrategyResult` and runs without
an authentication check. `StrategyResult#authenticated?` tells application code
whether a user is present; `auth_attempt_succeeded?` tells it whether the
current route's authentication attempt produced an authenticated result.

## Combine strategies with OR logic

Use comma-separated requirements when more than one credential mechanism may
satisfy the same route:

```text
GET /api/data Api::Data#show auth=session,api_key,oauth response=json
```

The chain behaves as follows:

1. Strategies run left to right.
2. The first authenticated success wins and later strategies do not run.
3. A plain failure allows the next strategy to run.
4. An anonymous success, such as `noauth`, is held as a fallback while the rest
   of the chain runs.
5. If every strategy fails, Otto returns an authentication or authorization
   failure. If an anonymous fallback exists and no terminal failure occurred,
   it wins.
6. A terminal authentication failure stops the chain immediately. Strategies
   should mark a failure terminal only when explicit credentials were presented,
   examined, and rejected. This prevents invalid credentials from degrading to
   an anonymous success in a mixed chain such as
   `auth=basicauth,noauth`.

Put the common and least expensive strategy first, but do not use ordering to
make invalid explicit credentials harmless: terminal failures are intentionally
fail-closed.

## Route-level roles

Add `role=` for a broad route-level authorization check:

```text
GET /admin     Admin::Dashboard auth=session role=admin
GET /edit      Editorial#edit auth=session role=admin,editor
```

Multiple roles use OR logic. The authenticated result can expose roles through,
in precedence order:

1. `result.user_roles`
2. `result.user[:roles]` or `result.user['roles']`
3. `result.metadata[:user_roles]`

Missing authentication returns `401`. A valid authenticated subject without one
of the required roles returns `403`. `response=json` makes these route errors
JSON regardless of the request's `Accept` header.

## Resource-level authorization

Route-level roles cannot decide ownership or relationship rules without loading
the resource. Put that decision in a Logic class's `raise_concerns` method:

```ruby
class Posts::Edit
  def initialize(strategy_result, params, _locale)
    @context = strategy_result
    @params = params
  end

  def raise_concerns
    @post = Post.find(@params[:id])
    return if @post.user_id == @context.user_id

    raise Otto::Security::AuthorizationError.new(
      'Cannot edit another user\'s post',
      resource: 'Post',
      action: 'edit',
      user_id: @context.user_id
    )
  end

  def process
    # Perform the edit.
  end
end
```

`Otto::Security::AuthorizationError` is registered automatically and produces a
`403` response. It can carry resource, action, and user ID context for structured
logging. Authenticate first, then perform resource-level checks; do not rely on
an ownership check as a substitute for authentication.

## Strategy result contract

Otto stores the result for the request in `env['otto.strategy_result']` and uses
it to construct Logic-class context. Useful accessors include:

```ruby
result.authenticated?
result.anonymous?
result.user_id
result.user_name
result.has_role?('admin')
result.has_permission?('write')
result.session
result.metadata
result.strategy_name
```

Application code should read the result created by Otto rather than constructing
its own `StrategyResult`. The result is immutable.

## Failure and response behavior

- Unknown strategy names fail before any strategy in the route runs.
- Authentication failures are `401`; browser-oriented failures may redirect to
  the configured login path, while JSON routes return JSON.
- Authorization failures are `403` and should not ask an already authenticated
  subject to authenticate again.
- A strategy should return an `AuthorizationFailure` when credentials are valid
  but the subject is not permitted, and an `AuthFailure` when authentication did
  not succeed.
- Failure reasons and attempted strategies are included in Otto's structured
  authentication logging; do not put secrets or raw credentials in those
  reasons.

## Built-in strategy starting points

Otto includes these strategy classes as implementation starting points:

- `SessionStrategy` — reads a configured key from `env['rack.session']`.
- `APIKeyStrategy` — checks the configured header first and then a query
  parameter; configure a non-empty key set for actual validation.
- `RoleStrategy` — checks session roles against allowed roles or a
  colon-qualified requirement.
- `PermissionStrategy` — checks application-provided permission data.
- `NoAuthStrategy` — produces an anonymous success for an explicitly configured
  anonymous fallback.

For production credentials, choose the credential storage, rotation, transport,
and revocation policy in the application. Otto supplies the route boundary and
result contract; it does not provide a user database or a universal session
store.

## Related contracts

- [Route syntax](../reference/route-syntax.md) — `auth=`, `role=`, and route
  parsing rules.
- [Routing guide](routing.md) — choosing controller, Logic, and lambda handlers.
- [Configuration freezing](../configuration_freezing.md) — boot-time mutation
  boundary and multi-step setup.
