# IP Privacy Documentation

Otto automatically masks public IP addresses by default to enhance privacy and comply with data protection regulations (GDPR, CCPA, etc.). Private and localhost IPs are never masked for development convenience.

## How It Works

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

## Multi-Layer Middleware Architecture

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

## What Gets Anonymized

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

# PRIVATE/LOCALHOST IPs (never masked by default):
env['REMOTE_ADDR']                  # => '127.0.0.1' (unchanged)
env['HTTP_USER_AGENT']              # => '...' (unchanged, raw value)
env['HTTP_REFERER']                 # => 'https://...' (unchanged, raw value)
env['otto.original_ip']             # => '127.0.0.1' (available for debugging)
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

## Configuration

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

## Multi-Server Support with Redis

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

## Use Cases

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

## Proxy Support

Otto's IP privacy middleware fully supports proxy scenarios by resolving the actual client IP from X-Forwarded-For headers before applying privacy masking.

### How Proxy Resolution Works

1. **Trusted Proxy Configuration**: Configure proxies via `otto.add_trusted_proxy(ip_or_pattern)`
2. **Client IP Resolution**: Middleware checks X-Forwarded-For headers from trusted proxies
3. **Privacy Masking**: Resolved client IP is then masked (if public) or exempted (if private)
4. **Header Replacement**: Both `REMOTE_ADDR` and forwarded headers are replaced with masked values

### Configuration

```ruby
# Configure trusted proxies (load balancers, reverse proxies, CDNs)
otto.add_trusted_proxy('10.0.0.1')                  # Exact IP
otto.add_trusted_proxy('172.16.0.0/12')             # CIDR range (not yet implemented)
otto.add_trusted_proxy(/^192\.168\./)               # Regex pattern
```

### Behavior Examples

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

**Scenario 3: Untrusted Proxy (Security)**
```ruby
# Request: Malicious client trying to spoof X-Forwarded-For
env['REMOTE_ADDR'] = '198.51.100.1'            # NOT in trusted proxies
env['HTTP_X_FORWARDED_FOR'] = '203.0.113.50'  # Untrusted header (ignored)

# After IPPrivacyMiddleware:
env['REMOTE_ADDR']          # => '198.51.100.0' (proxy IP masked, header ignored)
env['HTTP_X_FORWARDED_FOR'] # => '198.51.100.0' (masked to match REMOTE_ADDR)
env['otto.masked_ip']       # => '198.51.100.0'
```

## Geo-Location Resolution

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

## Privacy Guarantees

1. **No Accidental Leaks**: Original public IPs never stored (private/localhost IPs available)
2. **GDPR Compliant**: Masked public IPs are not personally identifiable
3. **Session Correlation**: Daily-rotating hashed IPs enable analytics without tracking
4. **Geo-Analytics**: Country-level location data without privacy invasion
5. **User Agent Privacy**: Version numbers stripped to reduce fingerprinting
6. **Development Friendly**: Localhost and private IPs never masked for debugging
