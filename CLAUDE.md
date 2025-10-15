# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Authentication Architecture

**IMPORTANT**: Authentication in Otto is handled by `RouteAuthWrapper` at the handler level, NOT by middleware.

- Authentication strategies are configured via `otto.add_auth_strategy(name, strategy)`
- RouteAuthWrapper automatically wraps routes that have `auth` requirements
- When a route has an auth requirement, RouteAuthWrapper:
  1. Looks up the appropriate strategy from `auth_config[:auth_strategies]`
  2. Executes `strategy.authenticate(env, requirement)`
  3. Returns 401/302 if authentication fails (FailureResult)
  4. Sets `env['rack.session']`, `env['otto.strategy_result']`, `env['otto.user']` on success
  5. Calls the wrapped handler

- Strategy pattern matching supports:
  - Exact match: `'authenticated'` → looks up `auth_config[:auth_strategies]['authenticated']`
  - Prefix match: `'role:admin'` → looks up `'role'` strategy
  - Fallback: `'role:*'` → creates default RoleStrategy
  - Results are cached per wrapper instance

- `enable_authentication!` is a no-op kept for API compatibility
- AuthenticationMiddleware was removed (it was architecturally broken)

## Configuration Freezing

**IMPORTANT**: Otto automatically freezes all configuration at the end of initialization to prevent runtime security bypasses.

### How It Works

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

### What Gets Frozen

- **Security Config**: All security settings including CSRF, validation, rate limiting, and headers
- **Middleware Stack**: Prevents adding, removing, or modifying middleware after initialization
- **Routes**: All route structures (`@routes`, `@routes_literal`, `@routes_static`, `@route_definitions`)
- **Configuration Hashes**: `@auth_config`, `@locale_config`, `@option` and all nested structures

### Security Guarantees

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

### Multi-Step Initialization Pattern

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

### Testing Considerations

- Freezing is **automatically disabled** when `RSpec` is defined
- For manual unfreezing in tests, use `Otto.unfreeze_for_testing(otto)` (requires RSpec to be defined)
- **Never** use `unfreeze_for_testing` in production code - it raises an error if RSpec is not defined

### Implementation Details

- Lazy freezing occurs in `Otto#call` on first request (thread-safe with mutex)
- `@configuration_frozen` flag tracks freeze state (checked by `ensure_not_frozen!`)
- `Otto::Core::Freezable` module provides `deep_freeze!` method
- `MiddlewareStack` and `Security::Config` override `deep_freeze!` to pre-compute memoized values
- Uses `defined?()` pattern instead of `||=` for freeze-compatible memoization
- All mutation methods check `frozen_configuration?` and raise `FrozenError` when frozen

## IP Privacy (Privacy by Default)

**IMPORTANT**: Otto automatically masks public IP addresses by default to enhance privacy and comply with data protection regulations (GDPR, CCPA, etc.). **Private and localhost IPs are never masked** for development convenience.

### How It Works

1. **Privacy by Default**: `IPPrivacyMiddleware` is added FIRST in the middleware stack during initialization
2. **Smart Masking**:
   - **Public IPs**: Automatically masked (192.0.2.100 → 192.0.2.0)
   - **Private IPs**: Never masked (192.168.1.100, 10.0.0.5, 172.16.0.1)
   - **Localhost**: Never masked (127.0.0.1, ::1)
3. **No Original IP Storage**: When privacy is enabled, original public IPs are NEVER stored in `env`
4. **Middleware Runs First**: Processes IPs before authentication, rate limiting, or any application code

### Multi-Layer Middleware Architecture

For complex applications with multiple middleware layers (common in monolith/multi-app architectures), IPPrivacyMiddleware should be added to your **common middleware stack** before logging/monitoring middleware:

```ruby
# ❌ WRONG: Adding privacy only to Otto's internal stack
# Problem: CommonLogger runs before Otto, logging real IPs
builder.use Rack::CommonLogger
builder.use OtherMiddleware
# ... later: Otto router with its internal privacy middleware
# CommonLogger already logged real IP!

# ✅ CORRECT: Add privacy to common stack FIRST
builder.use Otto::Security::Middleware::IPPrivacyMiddleware  # <-- FIRST!
builder.use Rack::CommonLogger  # Now logs masked IPs
builder.use Rack::Parser
builder.use YourSessionMiddleware
builder.use Sentry::Rack::CaptureExceptions  # Captures masked IPs
# ... later: Otto router (its internal privacy middleware is redundant but harmless)
```

**Why this matters:**

Otto's internal middleware stack only runs when the request reaches the Otto router. If you have logging, error monitoring (Sentry), or other middleware that runs **before** the router, they will see and potentially log real IP addresses, defeating the purpose of IP privacy.

**Architecture layers:**
1. **Common Middleware** (all apps): Rack::CommonLogger, Sentry, Session, etc.
2. **App-Specific Middleware**: Request setup, error handling, etc.
3. **Otto Internal Middleware**: Privacy (redundant but harmless), CSRF, rate limiting, etc.

**Key insight:** IP privacy is a **Rack concern**, not a routing concern. It should run before any middleware that touches IPs (logging, monitoring, rate limiting).

**Usage in multi-app setups:**

```ruby
# In your common middleware configuration
module YourApp
  module MiddlewareStack
    def self.configure(builder)
      # IP Privacy FIRST - masks public IPs before logging/monitoring
      # Private/localhost IPs are automatically exempted for development
      builder.use Otto::Security::Middleware::IPPrivacyMiddleware

      builder.use Rack::CommonLogger  # Now logs masked IPs
      builder.use YourSession
      builder.use Sentry::Rack::CaptureExceptions  # Captures masked IPs
      # ... rest of common middleware
    end
  end
end

# In your app-specific code
class YourApp < Rack::Application
  use AppSpecificMiddleware

  def build_router
    Otto.new(routes)  # Otto's internal privacy middleware is redundant but harmless
  end
end
```

**Notes:**
- IPPrivacyMiddleware is idempotent - running it twice doesn't re-mask already-masked IPs
- Otto still adds it internally for backward compatibility with single-layer apps
- Private/localhost IPs are always exempted, making development seamless

### What Gets Anonymized

```ruby
# PUBLIC IPs (masked by default):
env['REMOTE_ADDR']                  # => '8.8.8.0' (masked)
env['otto.masked_ip']               # => '8.8.8.0' (same as REMOTE_ADDR)
env['otto.hashed_ip']               # => 'a3f8b2...' (daily-rotating hash)
env['otto.geo_country']             # => 'US' (country-level only)
env['otto.private_fingerprint']     # => PrivateFingerprint object
env['otto.original_ip']             # => nil (NOT available)

# PrivateFingerprint contains:
fingerprint.masked_ip               # => '8.8.8.0'
fingerprint.hashed_ip               # => 'a3f8b2...' (for session correlation)
fingerprint.country                 # => 'US'
fingerprint.anonymized_ua           # => 'Mozilla/X.X (Windows NT X.X...)'
fingerprint.session_id              # => UUID
fingerprint.timestamp               # => UTC timestamp

# PRIVATE/LOCALHOST IPs (never masked):
env['REMOTE_ADDR']                  # => '127.0.0.1' (unchanged)
env['otto.original_ip']             # => '127.0.0.1' (available)
env['otto.masked_ip']               # => nil
env['otto.hashed_ip']               # => nil
env['otto.private_fingerprint']     # => nil (not created)
```

### Request Helper Methods

```ruby
# For PUBLIC IPs (privacy enabled by default):
req.masked_ip                       # => '8.8.8.0'
req.hashed_ip                       # => 'a3f8b2...'
req.geo_country                     # => 'US'
req.anonymized_user_agent           # => 'Mozilla/X.X...'
req.private_fingerprint             # => Full PrivateFingerprint object
req.ip                              # => '8.8.8.0' (masked)

# For PRIVATE/LOCALHOST IPs (never masked):
req.masked_ip                       # => nil
req.hashed_ip                       # => nil
req.private_fingerprint             # => nil
req.ip                              # => '127.0.0.1' (real IP)
```

### Configuration

```ruby
# Default: Privacy enabled, 1 octet masked (public IPs only)
otto = Otto.new(routes_file)
# Public IPs masked: 8.8.8.8 → 8.8.8.0
# Private IPs unchanged: 127.0.0.1, 192.168.1.100, 10.0.0.5

# Customize privacy settings (still enabled)
otto.configure_ip_privacy(
  mask_level: 2,          # Mask 2 octets (8.8.0.0)
  hash_rotation: 12.hours, # Rotate hashing key every 12 hours
  geo: false              # Disable geo-location
)

# Multi-server environment with Redis (atomic key generation)
redis = Redis.new(url: ENV['REDIS_URL'])
otto.configure_ip_privacy(redis: redis)
# All servers share same rotation key via Redis SET NX GET EX
# Single source of truth for IP hashing across cluster

# Explicitly disable privacy (NOT recommended)
otto.disable_ip_privacy!
# ALL IPs unmasked (including public IPs)
# env['REMOTE_ADDR'] contains real IP
# env['otto.original_ip'] also available
```

### Multi-Server Support with Redis

For applications running across multiple servers, Otto supports Redis-based atomic key generation to ensure all servers use the same rotation key:

```ruby
# Single-server (default): In-memory Concurrent::Hash
otto = Otto.new(routes_file)
# Each server generates its own keys
# Works fine for single-server deployments

# Multi-server: Redis-based atomic key generation
redis = Redis.new(url: ENV['REDIS_URL'])
otto = Otto.new(routes_file)
otto.configure_ip_privacy(redis: redis)
# All servers share keys via Redis SET NX GET EX
# Guaranteed consistency across entire cluster
```

**How Redis key generation works:**
1. Uses `SET key value NX GET EX ttl` for atomic operations
2. Returns existing key if present, otherwise sets and returns new key
3. Keys auto-expire after 1.2× rotation period (20% buffer)
4. No manual cleanup required
5. Single source of truth across all application servers

**Redis key format:**
```
rotation_key:{timestamp}  # e.g., rotation_key:1704067200
```

**Benefits:**
- **Consistency**: Same IP always hashes to same value across all servers
- **Atomic**: No race conditions when rotation occurs
- **Auto-cleanup**: TTL handles key expiration automatically
- **Scalable**: Works with any number of application servers
- **Fallback**: Automatically falls back to in-memory if Redis unavailable

```

### Use Cases

**Session Correlation Without Tracking:**
```ruby
# Use hashed IP for rate limiting/analytics without storing real IPs
Rack::Attack.throttle('requests/ip', limit: 100, period: 60) do |req|
  req.hashed_ip  # Daily-rotating hash allows session tracking
end
```

**Geo-Analytics Without Privacy Invasion:**
```ruby
# Country-level analytics without precise location
class Analytics
  def track_request(req)
    log({
      country: req.geo_country,      # 'US' (country-level only)
      masked_ip: req.masked_ip,      # '192.168.1.0'
      path: req.path
    })
  end
end
```

**Privacy-Compliant Logging:**
```ruby
# Log requests with privacy-safe fingerprints
class RequestLogger
  def log(req)
    fingerprint = req.private_fingerprint
    Rails.logger.info(fingerprint.to_json)
    # Original IP never logged
  end
end
```

### Authentication Integration

RouteAuthWrapper and authentication strategies automatically use masked IPs for public addresses:

```ruby
# Public IP (masked by default):
result = StrategyResult.anonymous(metadata: { ip: env['REMOTE_ADDR'] })
result.user_context[:ip]  # => '8.8.8.0' (masked)

metadata = {
  ip: env['REMOTE_ADDR'],           # '8.8.8.0' (masked)
  country: env['otto.geo_country'], # 'US'
  auth_failure: 'Invalid credentials'
}

# Private/localhost IP (never masked):
result.user_context[:ip]  # => '127.0.0.1' (real IP)
```

### Privacy Guarantees

1. **No Accidental Leaks**: Original public IPs never stored (private/localhost IPs available)
2. **GDPR Compliant**: Masked public IPs are not personally identifiable
3. **Session Correlation**: Daily-rotating hashed IPs enable analytics without tracking
4. **Geo-Analytics**: Country-level location data without privacy invasion
5. **User Agent Privacy**: Version numbers stripped to reduce fingerprinting
6. **Development Friendly**: Localhost and private IPs never masked for debugging

### Geo-Location Resolution

Uses multiple sources (no external APIs required):

1. **CloudFlare Headers** (most reliable): `CF-IPCountry` header
2. **IP Range Detection**: Basic detection for major providers (Google, AWS, etc.)
3. **Unknown Fallback**: Returns 'XX' for unresolved IPs

### Testing Considerations

- In test environment (RSpec), privacy is enabled by default
- Private IPs (including 127.0.0.1) are never masked, making tests straightforward
- Use `Otto.unfreeze_for_testing(otto)` before calling `disable_ip_privacy!` in tests
- Helper methods like `req.private_fingerprint` return nil for private/localhost IPs

## Development Commands

### Setup
```bash
# Install development and test dependencies
bundle config set with 'development test'
bundle install

# Lint code
bundle exec rubocop

# Run tests
bundle exec rspec

# Run a specific test
bundle exec rspec spec/path/to/specific_spec.rb
# rspec settings in .rspec
```

## Project Overview

### Core Components
- Ruby Rack-based web framework for defining web applications
- Focuses on security and simplicity
- Supports internationalization and optional security features

### Key Features
- Plain-text routes configuration
- Automatic locale detection
- Privacy by default:
  - Automatic public IP masking (private/localhost IPs exempted)
  - Daily-rotating IP hashing for session correlation
  - Country-level geo-location (no external APIs)
  - User agent anonymization
- Optional security features:
  - CSRF protection
  - Input validation
  - Security headers
  - Trusted proxy configuration

### Test Frameworks
- RSpec for unit and integration testing
- Tryouts for behavior-driven testing

### Development Tools
- Rubocop for linting
- Debug gem for debugging
- Tryouts for alternative testing approach

### Ruby Version Requirements
- Ruby 3.2+
- Rack 3.1+

### Important Notes
- Always validate and sanitize user inputs
- Leverage built-in security features
- Use locale helpers for internationalization support
