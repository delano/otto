# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Error Handler Registration

**IMPORTANT**: Otto supports registering handlers for expected business logic errors to avoid logging them as unhandled 500 errors.

### Basic Usage

Register error handlers during Otto initialization (before first request):

```ruby
otto = Otto.new('routes.txt')

# Register expected errors with status codes and log levels
otto.register_error_handler(Onetime::MissingSecret, status: 404, log_level: :info)
otto.register_error_handler(Onetime::SecretExpired, status: 410, log_level: :info)
otto.register_error_handler(Onetime::RateLimited, status: 429, log_level: :warn)
```

### Custom Response Handlers

For more control over the error response, provide a block:

```ruby
otto.register_error_handler(Onetime::RateLimited, status: 429, log_level: :warn) do |error, req|
  {
    error: 'Rate limit exceeded',
    retry_after: error.retry_after,
    message: error.message,
    client_id: req.params[:client_id]
  }
end
```

### How It Works

When a registered error is raised:
1. **Status Code**: Returns the configured HTTP status (not 500)
2. **Log Level**: Logs at configured level (:info, :warn) instead of :error
3. **No Backtrace**: Expected errors don't generate backtraces
4. **Content Negotiation**: Automatically returns JSON or plain text based on Accept header
5. **Error ID**: Still generates correlation ID for debugging (shown in dev mode only)

### Log Output Comparison

**Unregistered error (logged as 500)**:
```
E [54845] Otto -- Unhandled error in request -- {error: "Secret not found", error_class: "Onetime::MissingSecret", error_id: "abc123"}
E [54845] Otto -- Exception backtrace -- {error_id: "abc123", backtrace: [...]}
```

**Registered error (logged at info level)**:
```
I [54845] Otto -- Expected error in request -- {error: "Secret not found", error_class: "Onetime::MissingSecret", error_id: "abc123", expected: true}
```

### Use Cases

**Common expected errors:**
- `MissingResource` → 404 Not Found
- `ExpiredResource` → 410 Gone
- `RateLimited` → 429 Too Many Requests
- `Unauthorized` → 401 Unauthorized
- `ValidationFailed` → 422 Unprocessable Entity

**Integration with Logic Classes:**

Since Logic classes use `raise_concerns` for validation, register handlers for those concerns:

```ruby
otto.register_error_handler(YourApp::InvalidInput, status: 422, log_level: :warn)
otto.register_error_handler(YourApp::PermissionDenied, status: 403, log_level: :warn)
```

### String Class Names (Lazy Loading)

For errors that may not be loaded yet:

```ruby
otto.register_error_handler('SomeModule::SomeError', status: 422, log_level: :warn)
```

### Configuration Freezing

Error handlers must be registered before the first request (before configuration freezing):

```ruby
otto = Otto.new('routes.txt')
otto.register_error_handler(MyError, status: 404)  # ✓ OK

# First request triggers freezing
otto.call(env)

otto.register_error_handler(AnotherError, status: 404)  # ✗ FrozenError!
```

## Authentication Architecture

**IMPORTANT**: Authentication in Otto is handled by `RouteAuthWrapper` at the handler level, NOT by middleware.

### Basic Configuration

- Authentication strategies are configured via `otto.add_auth_strategy(name, strategy)`
- RouteAuthWrapper automatically wraps routes that have `auth` requirements
- Strategy names must be unique (duplicate registration raises ArgumentError)
- When a route has an auth requirement, RouteAuthWrapper:
  1. Looks up the appropriate strategy from `auth_config[:auth_strategies]`
  2. Executes `strategy.authenticate(env, requirement)`
  3. Returns 401/302 if authentication fails (FailureResult)
  4. Sets `env['rack.session']`, `env['otto.strategy_result']` on success
  5. Calls the wrapped handler

### Multi-Strategy Authentication (OR Logic)

**Routes can specify multiple authentication strategies with comma-separated syntax:**

```ruby
# Routes file:
GET /api/data  DataLogic#show  auth=session,apikey,oauth
```

**Execution Flow:**
1. Strategies execute left-to-right in order
2. **First success wins** - remaining strategies are not executed
3. Returns 401 only if **all** strategies fail
4. Unknown strategies cause immediate 401 (strict mode)

**Example:**
```ruby
# Configure strategies
otto.add_auth_strategy('session', SessionStrategy.new)
otto.add_auth_strategy('apikey', APIKeyStrategy.new)
otto.add_auth_strategy('oauth', OAuthStrategy.new)

# Route with multi-strategy
# GET /api/data  DataLogic#show  auth=session,apikey,oauth
#
# Execution:
# 1. Tries 'session' strategy
# 2. If session succeeds → call handler (apikey/oauth not executed)
# 3. If session fails → try 'apikey' strategy
# 4. If apikey succeeds → call handler (oauth not executed)
# 5. If apikey fails → try 'oauth' strategy
# 6. If oauth succeeds → call handler
# 7. If all fail → return 401
```

**Performance:** Put fastest/most-common strategies first (e.g., `auth=session,apikey` instead of `auth=apikey,session`)

### Strategy Pattern Matching

- **Exact match**: `'authenticated'` → looks up `auth_config[:auth_strategies]['authenticated']`
- **Prefix match**: `'custom:value'` → looks up `'custom'` strategy and passes full requirement
- **Results are cached** per wrapper instance

**Note:** `auth=role:admin` syntax has been removed in favor of separate `role=` option for authorization (see Authorization section below)

### Two-Layer Authorization Pattern

Otto implements industry-standard separation between authentication and authorization:

**Layer 1: Route-Level (Authentication + Basic Authorization)**
- Handled by `RouteAuthWrapper` before handler execution
- Use `auth=` for authentication strategies
- Use `role=` for role-based route access (not yet implemented - use custom strategies for now)
- Fast execution (no database queries)
- Returns 401 (Unauthorized) or 403 (Forbidden) before reaching Logic class

**Layer 2: Resource-Level (Authorization)**
- Handled by Logic classes in `raise_concerns` method
- Checks ownership, relationships, resource attributes
- Requires database queries to load resources
- Raises `Otto::Security::AuthorizationError` for 403 response

**Example: Resource Ownership**
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

**Example: Multi-Condition Authorization**
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

**AuthorizationError Features:**
- Auto-registered during Otto initialization (returns 403)
- Logged at WARN level (not ERROR)
- Optional context: `resource`, `action`, `user_id` for debugging
- Supports structured logging via `to_log_data`

### Compatibility Notes

- `enable_authentication!` is a no-op kept for API compatibility
- AuthenticationMiddleware was removed (architecturally broken - ran before routing)

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
2. **Consistent Architecture**: Privacy middleware **replaces `env` values directly** for all sensitive data:
   - `env['REMOTE_ADDR']` → masked IP (e.g., `'9.9.9.0'`)
   - `env['HTTP_USER_AGENT']` → anonymized UA (versions stripped)
   - `env['HTTP_REFERER']` → anonymized referer (query params stripped)
3. **Smart Masking**:
   - **Public IPs**: Automatically masked (192.0.2.100 → 192.0.2.0)
   - **Private IPs**: Never masked (192.168.1.100, 10.0.0.5, 172.16.0.1)
   - **Localhost**: Never masked (127.0.0.1, ::1)
4. **No Original Values Storage**: When privacy is enabled, original public values are NEVER stored in `env`
5. **Middleware Runs First**: Processes all values before authentication, rate limiting, logging, or any application code
6. **Pit of Success**: Downstream code (logging, rate limiting, third-party gems) automatically gets anonymized values

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

**IMPORTANT**: Privacy middleware **replaces env values directly**. Downstream code automatically gets anonymized values without special handling.

```ruby
# PUBLIC IPs (privacy enabled - default):
env['REMOTE_ADDR']                  # => '9.9.9.0' (REPLACED with masked IP)
env['HTTP_USER_AGENT']              # => 'Mozilla/*.* (Windows NT *.*; Win64; x64) AppleWebKit/*.*' (REPLACED, versions stripped)
env['HTTP_REFERER']                 # => 'https://example.com/page' (REPLACED, query params stripped)
env['otto.privacy.masked_ip']       # => '9.9.9.0' (same as REMOTE_ADDR)
env['otto.privacy.hashed_ip']       # => 'a3f8b2...' (daily-rotating hash)
env['otto.privacy.geo_country']     # => 'US' (country-level only)
env['otto.privacy.fingerprint']     # => RedactedFingerprint object
env['otto.original_ip']             # => nil (NOT available - prevents leakage)
env['otto.original_user_agent']    # => nil (NOT available - prevents leakage)
env['otto.original_referer']       # => nil (NOT available - prevents leakage)

# RedactedFingerprint contains (for reference):
fingerprint.masked_ip               # => '9.9.9.0'
fingerprint.hashed_ip               # => 'a3f8b2...' (for session correlation)
fingerprint.country                 # => 'US'
fingerprint.anonymized_ua           # => 'Mozilla/*.* (Windows NT *.*...)'
fingerprint.referer                 # => 'https://example.com/page' (query params stripped)
fingerprint.session_id              # => UUID
fingerprint.timestamp               # => UTC timestamp

# PRIVATE/LOCALHOST IPs (never masked by default):
env['REMOTE_ADDR']                  # => '127.0.0.1' (unchanged)
env['HTTP_USER_AGENT']              # => '...' (unchanged, raw value)
env['HTTP_REFERER']                 # => 'https://...' (unchanged, raw value)
env['otto.original_ip']             # => '127.0.0.1' (available for debugging)
env['otto.original_user_agent']    # => nil (not set for private IPs)
env['otto.original_referer']       # => nil (not set for private IPs)
env['otto.privacy.masked_ip']       # => nil
env['otto.privacy.hashed_ip']       # => nil
env['otto.privacy.fingerprint']     # => nil (not created)

# PRIVACY DISABLED (otto.disable_ip_privacy!):
env['REMOTE_ADDR']                  # => '9.9.9.9' (unchanged, real IP)
env['HTTP_USER_AGENT']              # => 'Mozilla/5.0 Chrome/141.0.0.0' (unchanged, raw UA)
env['HTTP_REFERER']                 # => 'https://example.com/page?token=secret' (unchanged, with query params)
env['otto.original_ip']             # => '9.9.9.9' (available for explicit access)
env['otto.original_user_agent']    # => 'Mozilla/5.0 Chrome/141.0.0.0' (available for explicit access)
env['otto.original_referer']       # => 'https://example.com/page?token=secret' (available for explicit access)
env['otto.privacy.fingerprint']     # => nil (not created when disabled)
```

### Request Helper Methods

**IMPORTANT**: With the new architecture, most helper methods are **deprecated** in favor of using `env` directly.

```ruby
# RECOMMENDED: Use env directly (already anonymized when privacy enabled)
env['REMOTE_ADDR']                  # Already masked for public IPs
env['HTTP_USER_AGENT']              # Already anonymized for public IPs
env['HTTP_REFERER']                 # Already anonymized for public IPs

# Helper methods (maintained for backward compatibility):
req.ip                              # => env['REMOTE_ADDR'] (already masked)
req.user_agent                      # => env['HTTP_USER_AGENT'] (already anonymized)
req.anonymized_user_agent           # => DEPRECATED: same as user_agent
req.masked_ip                       # => env['otto.privacy.masked_ip'] || env['REMOTE_ADDR']
req.hashed_ip                       # => env['otto.privacy.hashed_ip']
req.geo_country                     # => env['otto.privacy.geo_country']
req.redacted_fingerprint            # => env['otto.privacy.fingerprint']

# For explicit access to original values (only when privacy disabled):
env['otto.original_ip']             # Real IP (only if privacy disabled)
env['otto.original_user_agent']    # Real UA (only if privacy disabled)
env['otto.original_referer']       # Real referer (only if privacy disabled)
```

**Migration Guide**:
- OLD: `req.anonymized_user_agent` → NEW: `env['HTTP_USER_AGENT']` (already anonymized)
- OLD: `req.masked_ip` → NEW: `env['REMOTE_ADDR']` (already masked)
- OLD: Access via RedactedFingerprint → NEW: Use `env` directly

### Configuration

```ruby
# Default: Privacy enabled, 1 octet masked (public IPs only)
otto = Otto.new(routes_file)
# Public IPs masked: 9.9.9.9 → 9.9.9.0
# Private IPs unchanged: 127.0.0.1, 192.168.1.100, 10.0.0.5

# Customize privacy settings (still enabled)
otto.configure_ip_privacy(
  octet_precision: 2,     # Mask 2 octets (9.9.0.0)
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
    fingerprint = req.redacted_fingerprint
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
result.user_context[:ip]  # => '9.9.9.0' (masked)

metadata = {
  ip: env['REMOTE_ADDR'],           # '9.9.9.0' (masked)
  country: env['otto.geo_country'], # 'CH'
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

Otto provides country-level geo-location without requiring external databases or API calls. It checks CDN/infrastructure provider headers with intelligent fallback to IP range detection.

**Supported CDN/Infrastructure Headers** (checked in priority order):

1. **Cloudflare**: `CF-IPCountry` (most widely deployed)
2. **AWS CloudFront**: `CloudFront-Viewer-Country`
3. **Fastly**: `Fastly-Client-IP-Country`
4. **Akamai**: `X-Akamai-Edgescape` (extracts from `country_code=XX` format)
5. **Azure Front Door**: `X-Azure-ClientIP-Country`
6. **Semi-standard headers**: `X-Geo-Country`, `X-Country-Code`, `Country-Code` (least reliable)
7. **IP Range Detection**: Basic detection for major providers (Google, AWS, etc.)
8. **Unknown Fallback**: Returns '**' for unresolved IPs

**Header Format**: All headers use ISO 3166-1 alpha-2 country codes (e.g., 'US', 'GB', 'DE')

**Validation**: Only valid 2-letter uppercase codes are accepted. Invalid headers are ignored and fallback continues.

**Examples**:
```ruby
# Cloudflare
env = { 'HTTP_CF_IPCOUNTRY' => 'US' }
GeoResolver.resolve('1.2.3.4', env)  # => 'US'

# AWS CloudFront
env = { 'HTTP_CLOUDFRONT_VIEWER_COUNTRY' => 'GB' }
GeoResolver.resolve('1.2.3.4', env)  # => 'GB'

# Akamai Edgescape
env = { 'HTTP_X_AKAMAI_EDGESCAPE' => 'country_code=FR,region_code=IDF' }
GeoResolver.resolve('1.2.3.4', env)  # => 'FR'

# Fallback to IP range
GeoResolver.resolve('8.8.8.8', {})   # => 'US' (Google DNS)

# Unknown IP
GeoResolver.resolve('240.0.0.1', {}) # => '**'
```

#### Extending Geo-Location Resolution

Otto provides a pluggable architecture for extending geo-location capabilities. Choose based on your needs:

**Configuration-Based (Proc/Lambda)** - Best for simple integrations:

```ruby
# Example: MaxMind GeoLite2 integration
Otto::Privacy::GeoResolver.custom_resolver = ->(ip, env) {
  reader = MaxMind::DB.new('GeoLite2-Country.mmdb')
  result = reader.get(ip)
  result&.dig('country', 'iso_code')
rescue StandardError
  nil  # Return nil to fall back to built-in resolution
}

# Example: External API with caching
class GeoAPIResolver
  def initialize(api_key)
    @api_key = api_key
    @cache = {}
  end

  def call(ip, _env)
    @cache[ip] ||= fetch_from_api(ip)
  rescue StandardError
    nil  # Fall back to built-in resolution
  end
end

Otto::Privacy::GeoResolver.custom_resolver = GeoAPIResolver.new(ENV['GEO_API_KEY'])
```

**Subclass-Based** - Best for complex logic or multiple method overrides:

```ruby
class ExtendedGeoResolver < Otto::Privacy::GeoResolver
  # Add custom IP ranges
  CUSTOM_RANGES = {
    IPAddr.new('100.64.0.0/10') => 'US',  # Carrier-grade NAT
  }.freeze

  def self.detect_by_range(ip)
    addr = IPAddr.new(ip)

    # Check custom ranges first
    CUSTOM_RANGES.each do |range, country|
      return country if range.include?(addr)
    end

    # Fall back to parent's built-in ranges
    super
  end
end
```

**Resolution Priority** (with custom resolver):
1. CDN/infrastructure headers (always checked first)
2. Custom resolver (if configured and returns valid code)
3. Built-in IP range detection
4. Unknown fallback ('**')

**Production Pattern: Bloom/Cuckoo Filters for RIR Data**

For production systems needing comprehensive IP coverage without external dependencies:

```ruby
# Bloom filter per country, built from RIR delegation files
# - Memory: ~1MB for entire IPv4 table at 1% FPR
# - Lookup: O(1) microsecond-level performance
# - Zero external dependencies (no GeoIP DB, no API calls)

class RIRBloomResolver < Otto::Privacy::GeoResolver
  # Load RIR delegation files from ARIN, RIPE, APNIC, etc.
  # Parse prefixes: registry|cc|type|start|value|date|status
  # Insert /8, /16, /19 prefixes into per-country Bloom filters

  def self.detect_by_range(ip)
    # Check Bloom filters: O(1) lookup, ~1-5μs
    # False positive rate: 0.5-1% ("possibly this country")
    # No false negatives ("definitely not" is trusted)
    super  # Fall back to built-in ranges
  end
end

# Benefits:
# - 40x smaller than GeoIP DB (3MB vs 40MB)
# - 20-50x faster lookups (1-5μs vs 50-100μs)
# - Nightly rebuild from public RIR files
# - Perfect for CDN header fallback scenarios
```

**See**: `examples/simple_geo_resolver.rb` for complete implementation examples including Bloom filter integration

### Proxy Support

**IMPORTANT**: Otto's IP privacy middleware fully supports proxy scenarios by resolving the actual client IP from X-Forwarded-For headers before applying privacy masking.

#### How Proxy Resolution Works

1. **Trusted Proxy Configuration**: Configure proxies via `otto.add_trusted_proxy(ip_or_pattern)`
2. **Client IP Resolution**: Middleware checks X-Forwarded-For headers from trusted proxies
3. **Privacy Masking**: Resolved client IP is then masked (if public) or exempted (if private)
4. **Header Replacement**: Both `REMOTE_ADDR` and forwarded headers are replaced with masked values

#### Proxy Header Priority

Headers are checked in this order:
1. `X-Forwarded-For` (first non-trusted IP in chain)
2. `X-Real-IP`
3. `X-Client-IP`

#### Configuration

```ruby
# Configure trusted proxies (load balancers, reverse proxies, CDNs)
otto.add_trusted_proxy('10.0.0.1')                  # Exact IP
otto.add_trusted_proxy('172.16.0.0/12')             # CIDR range (not yet implemented)
otto.add_trusted_proxy(/^192\.168\./)               # Regex pattern
```

#### Behavior Examples

**Scenario 1: Direct Connection (No Proxy)**
```ruby
# Request from client 203.0.113.50
env['REMOTE_ADDR'] = '203.0.113.50'

# After IPPrivacyMiddleware:
env['REMOTE_ADDR']          # => '203.0.113.0' (masked)
env['otto.masked_ip']       # => '203.0.113.0'
```

**Scenario 2: Trusted Proxy with Public Client IP**
```ruby
# Request: Client 203.0.113.50 → Proxy 10.0.0.1 → Otto
env['REMOTE_ADDR'] = '10.0.0.1'                # Trusted proxy
env['HTTP_X_FORWARDED_FOR'] = '203.0.113.50'   # Real client IP

# After IPPrivacyMiddleware:
env['REMOTE_ADDR']          # => '203.0.113.0' (resolved & masked)
env['HTTP_X_FORWARDED_FOR'] # => '203.0.113.0' (masked to prevent leaks)
env['otto.masked_ip']       # => '203.0.113.0'
```

**Scenario 3: Trusted Proxy with Private Client IP**
```ruby
# Request: Client 192.168.1.100 (internal) → Proxy 10.0.0.1 → Otto
env['REMOTE_ADDR'] = '10.0.0.1'
env['HTTP_X_FORWARDED_FOR'] = '192.168.1.100'  # Private client IP

# After IPPrivacyMiddleware:
env['REMOTE_ADDR']          # => '192.168.1.100' (resolved but NOT masked)
env['HTTP_X_FORWARDED_FOR'] # => '192.168.1.100' (not masked, private IP)
env['otto.original_ip']     # => '192.168.1.100'
```

**Scenario 4: Untrusted Proxy (Security)**
```ruby
# Request: Malicious client trying to spoof X-Forwarded-For
env['REMOTE_ADDR'] = '198.51.100.1'            # NOT in trusted proxies
env['HTTP_X_FORWARDED_FOR'] = '203.0.113.50'  # Untrusted header (ignored)

# After IPPrivacyMiddleware:
env['REMOTE_ADDR']          # => '198.51.100.0' (proxy IP masked, header ignored)
env['HTTP_X_FORWARDED_FOR'] # => '198.51.100.0' (masked to match REMOTE_ADDR)
env['otto.masked_ip']       # => '198.51.100.0'
```

**Scenario 5: Proxy Chain**
```ruby
# Request: Client → CDN → Load Balancer → Otto
# Both CDN and LB are trusted proxies
otto.add_trusted_proxy('172.16.0.1')  # Load balancer
otto.add_trusted_proxy(/^10\.0\./)    # CDN

env['REMOTE_ADDR'] = '172.16.0.1'
env['HTTP_X_FORWARDED_FOR'] = '203.0.113.50, 10.0.0.5, 172.16.0.1'

# After IPPrivacyMiddleware:
# Resolves to first non-trusted IP: 203.0.113.50
env['REMOTE_ADDR']          # => '203.0.113.0'
env['HTTP_X_FORWARDED_FOR'] # => '203.0.113.0'
```

#### Rack::Request#ip Compatibility

Otto does **NOT** override `Rack::Request#ip`. Instead, it ensures Rack's native proxy resolution works correctly with masked values:

1. IPPrivacyMiddleware resolves client IP from X-Forwarded-For
2. Masks both `REMOTE_ADDR` and forwarded headers
3. Rack's `request.ip` method uses these masked values naturally

```ruby
# Behind trusted proxy with privacy enabled
env['REMOTE_ADDR'] = '10.0.0.1'
env['HTTP_X_FORWARDED_FOR'] = '203.0.113.50'

# After IPPrivacyMiddleware:
request = Rack::Request.new(env)
request.ip  # => '203.0.113.0' (Rack resolves from masked headers)
```

This architecture allows:
- Rack's proxy logic to work unchanged
- No custom overrides needed
- Full compatibility with Rack middleware ecosystem

#### Common Proxy Configurations

**AWS ELB/ALB:**
```ruby
otto.add_trusted_proxy('10.0.0.0/8')   # Private VPC range
# ALB sets X-Forwarded-For header
```

**Cloudflare:**
```ruby
# Use Cloudflare's IP ranges (update periodically)
otto.add_trusted_proxy(/^173\.245\./)
otto.add_trusted_proxy(/^103\.21\./)
# ... add other Cloudflare ranges
# Cloudflare sets CF-IPCountry header (used for geo-location)
```

**nginx Reverse Proxy:**
```ruby
otto.add_trusted_proxy('127.0.0.1')
otto.add_trusted_proxy('::1')
# nginx sets X-Real-IP and X-Forwarded-For
```

#### Limitations and Edge Cases

1. **IPv6 Support**: Currently limited to IPv4 validation in `resolve_client_ip`
2. **CIDR Ranges**: String matching only (regex workaround available)
3. **Header Spoofing**: Always validate proxy configuration - untrusted sources are treated as direct connections
4. **Proxy Chain Length**: No limit, but only first non-trusted IP is used
5. **Header Format**: Expects standard comma-separated format for X-Forwarded-For

#### Security Considerations

- **Always configure trusted proxies explicitly** - don't trust all X-Forwarded-For headers
- **Verify proxy configuration in production** - incorrect config can expose real IPs
- **Monitor for header spoofing** - log suspicious X-Forwarded-For patterns
- **Use HTTPs between proxies and Otto** - prevent header injection attacks
- **Rotate hashing keys regularly** - use Redis for multi-server consistency

### Testing Considerations

- In test environment (RSpec), privacy is enabled by default
- Private IPs (including 127.0.0.1) are never masked, making tests straightforward
- Use `Otto.unfreeze_for_testing(otto)` before calling `disable_ip_privacy!` in tests
- Helper methods like `req.redacted_fingerprint` return nil for private/localhost IPs

## Structured Logging Conventions

**IMPORTANT**: Otto uses simple, explicit structured logging with timing capabilities. Avoid creating abstraction layers or event classes.

### LoggingHelpers Module

Otto provides several helper methods for consistent logging:

```ruby
# Request context extraction
Otto::LoggingHelpers.request_context(env)
# Returns: { method:, path:, ip:, country:, user_agent: }

# Timed operation logging
Otto::LoggingHelpers.log_timed_operation(level, message, env, **metadata) { block }
```

### Logging Patterns

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

### Timing Conventions

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

### Required Fields

All structured logs should include:
- **method** - HTTP method (GET, POST, etc.)
- **path** - Request path
- **ip** - Client IP (automatically masked by IPPrivacyMiddleware for public IPs)
- **duration** - Operation timing in microseconds (for timed operations)
- **Event-specific data** - Handler, type, error message, etc.

### Optional Fields

Include when relevant:
- **country** - Geo-location country code (from IPPrivacyMiddleware)
- **user_agent** - Browser/client info (truncated to 100 chars)
- **user_id** - Authenticated user ID
- **referrer** - HTTP Referer header
- **error** - Error message
- **error_class** - Error class name (for exceptions)

### Error Handling in Timed Operations

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

### Privacy Awareness

- IP addresses in logs are **already masked** by `IPPrivacyMiddleware` (public IPs only)
- Private IPs (127.0.0.1, 192.168.x.x, 10.x.x.x) are **never masked**
- `env['REMOTE_ADDR']` contains masked IP for public addresses
- User agents are automatically truncated to prevent log bloat

### Anti-Patterns

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

### Output Examples

**Example Output (with SemanticLogger or similar structured logger):**
```
I, [2025-01-21T14:39:39.462833 #82244] INFO -- : Template compiled -- {method: "GET", path: "/users", ip: "192.0.2.0", template_type: "handlebars", cached: false, duration: 68}
I, [2025-01-21T14:39:39.462926 #82244] INFO -- : View rendered -- {method: "GET", path: "/users", ip: "192.0.2.0", template: "user_profile", layout: "application", partials: ["header", "sidebar"], duration: 1118, response_size_bytes: 2048}
```

### Rationale

- **Simplicity**: Direct logging calls are easier to understand than abstraction layers
- **Explicitness**: You can see exactly what's being logged at the call site
- **Flexibility**: Easy to add one-off fields without modifying event classes
- **Performance**: No object allocation overhead for disabled debug logs
- **Consistency**: All timing in microseconds, automatic error handling for timed operations
- **Maintainability**: One helper file vs multiple event classes/helpers

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
