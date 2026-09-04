# Configuration Freezing Documentation

Otto automatically freezes all configuration at the end of initialization to prevent runtime security bypasses.

## How It Works

1. **Lazy Freezing**: Configuration freezing is deferred until the first request to support multi-step initialization
2. **Thread-Safe**: Uses mutex synchronization to ensure configuration is frozen exactly once
3. **Deep Freezing**: Uses recursive freezing to prevent modification at any nesting level
4. **Memoization-Compatible**: Pre-computes memoized values before freezing to avoid FrozenError

This lazy approach allows multi-app architectures (like OneTime Secret's registry-based system) to:
- Create Otto instances with `Otto.new(routes_file)`
- Add authentication strategies via `otto.add_auth_strategy(name, strategy)`
- Configure middleware with `otto.use(middleware)`
- Add security features via `otto.enable_csrf_protection!`
- All **before** the first request triggers freezing

## What Gets Frozen

- **Security Config**: All security settings including CSRF, validation, rate limiting, and headers
- **Middleware Stack**: Prevents adding, removing, or modifying middleware after initialization
- **Routes**: All route structures (`@routes`, `@routes_literal`, `@routes_static`, `@route_definitions`)
- **Configuration Hashes**: `@auth_config`, `@locale_config`, `@option` and all nested structures

## Security Guarantees

```ruby
# After first request, ALL of these will raise FrozenError:

# Direct modification attempts
otto.security_config.csrf_protection = false  # FrozenError!
otto.middleware.add(MaliciousMiddleware)       # FrozenError!

# Method-based modification attempts
otto.enable_csrf_protection!                   # FrozenError!
otto.add_trusted_proxy('evil.proxy')           # FrozenError!
otto.add_rate_limit_rule('bypass', limit: 999999) # FrozenError!

# Nested structure modification attempts
otto.security_config.rate_limiting_config[:custom_rules] = {} # FrozenError!
otto.auth_config[:auth_strategies] = {}        # FrozenError!
```

## Multi-Step Initialization Pattern

For complex applications that need to configure Otto after creation (e.g., multi-app architectures):

```ruby
# Step 1: Create Otto instance
otto = Otto.new('routes.txt')

# Step 2: Configure after initialization (BEFORE first request)
otto.add_auth_strategy('session', SessionStrategy.new(session_key: 'user_id'))
otto.add_auth_strategy('api_key', APIKeyStrategy.new(api_keys: ENV['API_KEYS']))
otto.enable_csrf_protection!
otto.use CustomMiddleware

# Step 3: First request triggers automatic freezing
# From this point on, configuration is immutable

# Later requests: Configuration is already frozen
# otto.add_auth_strategy(...)  # FrozenError!
```

This pattern is particularly useful for:
- Registry-based multi-app systems (like OneTime Secret)
- Applications that dynamically configure Otto based on environment
- Testing scenarios where configuration needs to happen in multiple phases

## Testing Considerations

- Freezing is **automatically disabled** when `RSpec` is defined
- For manual unfreezing in tests, use `Otto.unfreeze_for_testing(otto)` (requires RSpec to be defined)
- **Never** use `unfreeze_for_testing` in production code - it raises an error if RSpec is not defined

## Implementation Details

- Lazy freezing occurs in `Otto#call` on first request (thread-safe with mutex)
- `@configuration_frozen` flag tracks freeze state (checked by `ensure_not_frozen!`)
- `Otto::Core::Freezable` module provides `deep_freeze!` method
- `MiddlewareStack` and `Security::Config` override `deep_freeze!` to pre-compute memoized values
- Uses `defined?()` pattern instead of `||=` for freeze-compatible memoization
- All mutation methods check `frozen_configuration?` and raise `FrozenError` when frozen

## Error Handler Registration and Freezing

Error handlers must be registered before the first request (before configuration freezing):

```ruby
otto = Otto.new('routes.txt')
otto.register_error_handler(MyError, status: 404)  # ✓ OK

# First request triggers freezing
otto.call(env)

otto.register_error_handler(AnotherError, status: 404)  # ✗ FrozenError!
```

## Why Configuration Freezing Matters

Configuration freezing prevents several classes of security vulnerabilities:

1. **Runtime Configuration Tampering**: Prevents malicious code from disabling security features
2. **Middleware Injection**: Prevents insertion of malicious middleware after initialization
3. **Route Hijacking**: Prevents modification of routing tables at runtime
4. **Auth Strategy Bypass**: Prevents replacement of authentication strategies
5. **Rate Limit Bypass**: Prevents modification of rate limiting rules

The lazy freezing approach balances security with flexibility, allowing complex initialization patterns while ensuring runtime immutability.
