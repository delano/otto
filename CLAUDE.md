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

## IP Privacy (Opt-In)

**IMPORTANT**: Otto provides optional IP privacy features for enhanced data protection compliance (GDPR, CCPA, etc.). Privacy is **disabled by default** and must be explicitly enabled.

### How It Works

1. **Opt-In Model**: Privacy is disabled by default. Call `enable_ip_privacy!` to activate
2. **IP Masking**: When enabled, zeros out the last octet (IPv4) or last 80 bits (IPv6)
3. **No Original IP Storage**: When privacy is enabled, original IPs are NEVER stored in `env`
4. **Middleware Runs First**: When enabled, `IPPrivacyMiddleware` processes IPs before any other middleware

### Enabling IP Privacy

```ruby
# Enable with defaults (1 octet masking, geo-location enabled)
otto = Otto.new(routes_file)
otto.enable_ip_privacy!

# Enable with custom settings
otto = Otto.new(routes_file)
otto.enable_ip_privacy!(
  mask_level: 2,           # Mask 2 octets (192.168.0.0)
  hash_rotation: 12.hours, # Rotate hashing key every 12 hours
  geo: false               # Disable geo-location
)
```

### What Gets Anonymized

```ruby
# With privacy ENABLED:
env['REMOTE_ADDR']                  # => '192.168.1.0' (masked)
env['otto.masked_ip']               # => '192.168.1.0' (same as REMOTE_ADDR)
env['otto.hashed_ip']               # => 'a3f8b2...' (daily-rotating hash)
env['otto.geo_country']             # => 'US' (country-level only)
env['otto.private_fingerprint']     # => PrivateFingerprint object
env['otto.original_ip']             # => nil (NOT available)

# PrivateFingerprint contains:
fingerprint.masked_ip               # => '192.168.1.0'
fingerprint.hashed_ip               # => 'a3f8b2...' (for session correlation)
fingerprint.country                 # => 'US'
fingerprint.anonymized_ua           # => 'Mozilla/X.X (Windows NT X.X...)'
fingerprint.session_id              # => UUID
fingerprint.timestamp               # => UTC timestamp

# With privacy DISABLED (default):
env['REMOTE_ADDR']                  # => '192.168.1.100' (real IP)
env['otto.masked_ip']               # => nil
env['otto.hashed_ip']               # => nil
env['otto.private_fingerprint']     # => nil
```

### Request Helper Methods

```ruby
# When privacy is ENABLED:
req.masked_ip                       # => '192.168.1.0'
req.hashed_ip                       # => 'a3f8b2...'
req.geo_country                     # => 'US'
req.anonymized_user_agent           # => 'Mozilla/X.X...'
req.private_fingerprint             # => Full PrivateFingerprint object
req.ip                              # => '192.168.1.0' (masked)

# When privacy is DISABLED (default):
req.masked_ip                       # => nil
req.hashed_ip                       # => nil
req.private_fingerprint             # => nil
req.ip                              # => '192.168.1.100' (real IP)
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

RouteAuthWrapper and authentication strategies use env['REMOTE_ADDR'] which will be masked only if IP privacy is enabled:

```ruby
# When privacy is enabled:
result = StrategyResult.anonymous(metadata: { ip: env['REMOTE_ADDR'] })
result.user_context[:ip]  # => '192.168.1.0' (masked)

metadata = {
  ip: env['REMOTE_ADDR'],           # Masked
  country: env['otto.geo_country'], # 'US'
  auth_failure: 'Invalid credentials'
}

# When privacy is disabled (default):
result.user_context[:ip]  # => '192.168.1.100' (real IP)
```

### Privacy Guarantees (When Enabled)

1. **No Accidental Leaks**: Original IPs never stored when privacy is enabled
2. **GDPR Compliant**: Masked IPs are not personally identifiable
3. **Session Correlation**: Daily-rotating hashed IPs enable analytics without tracking
4. **Geo-Analytics**: Country-level location data without privacy invasion
5. **User Agent Privacy**: Version numbers stripped to reduce fingerprinting

### Geo-Location Resolution

Uses multiple sources (no external APIs required):

1. **CloudFlare Headers** (most reliable): `CF-IPCountry` header
2. **IP Range Detection**: Basic detection for major providers (Google, AWS, etc.)
3. **Unknown Fallback**: Returns 'XX' for unresolved IPs

### Testing Considerations

- In test environment (RSpec), privacy is disabled by default (opt-in)
- Use `otto.enable_ip_privacy!` to enable privacy features in tests
- Helper methods like `req.private_fingerprint` return nil when privacy is disabled

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
- Optional security features:
  - IP privacy (opt-in):
    - IP address masking
    - Daily-rotating IP hashing for session correlation
    - Country-level geo-location (no external APIs)
    - User agent anonymization
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
