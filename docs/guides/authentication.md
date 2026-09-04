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
api_keys = ENV.fetch('API_KEYS').split(',').reject(&:empty?)
raise 'API_KEYS is empty' if api_keys.empty?

otto.add_auth_strategy(
  'api_key',
  Otto::Security::Authentication::Strategies::APIKeyStrategy.new(api_keys: api_keys)
)
```

`APIKeyStrategy` fails closed. Its constructor requires exactly one key source
(`api_keys:`, `resolver:`, or a block; see below) and raises `ArgumentError`
when none is given, or when an `api_keys:` list normalizes to empty (`[]` or
only blank strings), so the strategy enforces the check the example above makes
explicit. A request that presents a key is accepted only when that key matches a
configured key under constant-time comparison; an empty credential is rejected.
A presented-but-invalid key is a terminal failure, so it aborts the strategy
chain instead of falling through to a later strategy in a multi-strategy `OR`
route.

The strategy reads the `X-API-Key` header only. The query/form parameter path is
opt-in via `param_name:`, because a key placed in a URL is captured by access
logs, proxies, and browser history:

```ruby
Otto::Security::Authentication::Strategies::APIKeyStrategy.new(
  api_keys: api_keys,
  param_name: 'api_key' # caution: keys in URLs are logged; prefer the header
)
```

The strategy never places the raw key in the result. `metadata[:api_key_fingerprint]`
(and, for the static list, `user[:api_key_fingerprint]`) holds a truncated
SHA-256 digest of the presented key, so audit logs can correlate requests
without recording the credential. With a resolver, `user` is whatever the
resolver returns, so that guarantee covers only the strategy's own fields; see
the rules below.

### Resolve keys from a database

A static list is the simple default. When keys live in a database, a
repository, or a cache, give the strategy a resolver instead. The resolver
receives the presented key and returns the account behind it, or `nil` when
there is none:

```ruby
APIKeyStrategy = Otto::Security::Authentication::Strategies::APIKeyStrategy

otto.add_auth_strategy(
  'api_key',
  APIKeyStrategy.new do |presented_key|
    ApiKey.find_by(digest: APIKeyStrategy.digest(presented_key))&.account
  end
)
```

Anything that responds to `#call` works as well, passed as `resolver:`:

```ruby
APIKeyStrategy.new(resolver: repo.method(:find_by_key))
APIKeyStrategy.new(resolver: ->(key) { KeyCache.fetch(APIKeyStrategy.digest(key)) })
```

The rules are the same in every form:

- Exactly one source: `api_keys:`, `resolver:`, or a block. Passing none, or
  more than one, raises `ArgumentError`, as does a `resolver:` that does not
  respond to `#call`.
- The resolver receives only the presented key, as a non-empty `String`, and
  nothing else. The blank check and the non-String rejection run before it, so
  a missing header is still the non-terminal `No API key provided` failure and
  the resolver is never asked about it.
- A `nil` or `false` return is a terminal `Invalid API key` failure, identical
  to a static mismatch. It aborts the strategy chain with a 401. Every other
  return value is a match, including empty containers: a `where(...)` relation,
  an empty Array from `select`, or `{}` from a cache miss is truthy and
  authenticates every presented key. Return one record (`find_by`, `first`) or
  `nil`.
- Exceptions from the resolver propagate. The strategy does not rescue them,
  so a database outage surfaces as an error rather than a silent 401, and can
  never become a success.
- Whatever the resolver returns becomes `user` in the result, verbatim, and
  `api_key_fingerprint` is still set in the result metadata. The strategy
  itself never places the raw key in the result, but the result is stored in
  `env['otto.strategy_result']` and exposed to handlers, so anything the
  application serializes or logs from it carries `user`. It is the resolver's
  responsibility not to return an object that carries the raw key. Return the
  account, not the `ApiKey` row that stores the key, and store digests. A
  resolver that returns the presented key string itself as the user raises
  `ArgumentError`.

The strategy cannot make a black-box lookup constant-time. Store SHA-256
digests rather than raw keys and look up by `APIKeyStrategy.digest(key)`, as
in the example above. The digest step is constant-time by construction, the
lookup that follows is an exact match on a fixed-width value, and a database
dump of high-entropy keys (generate them with `SecureRandom`, 32 bytes or
more) does not expose usable credentials. Unsalted SHA-256 is not a password
hash, so do not accept user-chosen keys. `APIKeyStrategy.digest(key)` returns
the full hex digest; the fingerprint in the result is its first 12 characters.

### What `APIKeyStrategy` does not provide

`APIKeyStrategy` is a conventional small static-allowlist authenticator
included as a low-dependency convenience and reference implementation. The
fail-closed changes in #256 make that existing convenience safe by default;
they do not establish that all Otto API-key authentication should use
boot-loaded lists.

In either form, the strategy has no native support for:

- Runtime addition or immediate revocation.
- Expiration.
- Per-client roles or scopes.
- Ownership and descriptive metadata.
- Usage quotas.
- A management API.
- Persisted audit history.
- Hashed verifier storage.

With a static list, none of these exist: changing the set of valid keys means
restarting the process, and every key is equal. With a resolver, the first
four and the last become the application's key store's responsibility. The
resolver decides whether a key is still valid, and whatever it returns is the
`user` the handler sees, so roles, scopes, ownership, and expiry live on that
record. Quotas, a management API, and audit history remain outside the
strategy entirely. An application that needs them should build a custom
`AuthStrategy` around its own key model, using `APIKeyStrategy` as the
reference for header handling, terminal failures, and fingerprinting.

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
- `APIKeyStrategy` — checks the configured header; the query parameter is opt-in
  via `param_name:`. Keys come from a non-empty `api_keys:` list, a `resolver:`
  callable, or a block that looks the presented key up; a rejected key is a
  terminal failure, and the result exposes only a key fingerprint.
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
- Configuration freezing (`Otto::Core::Freezable`) — boot-time mutation
  boundary and multi-step setup.
