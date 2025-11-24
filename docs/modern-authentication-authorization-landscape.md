# Modern Authentication/Authorization Landscape

## Overview

This document analyzes modern authentication and authorization patterns across web frameworks and libraries to inform Otto's design decisions regarding multiple authentication strategies per route.

**Research Date:** November 2025
**Frameworks Analyzed:** Warden (Ruby/Rack), Django REST Framework (Python), Passport.js (Node.js/Express)

---

## Industry-Standard Pattern: Multiple Strategies with OR Logic

**All major frameworks support multiple authentication strategies per route**, and they follow the same pattern:

### 1. Warden (Ruby/Rack) - The Reference Implementation

```ruby
# Warden explicitly supports cascading strategies
manager.default_strategies :session, :token, :basic

# "Warden looks through all valid strategies and attempts to
# authenticate until one works"
```

**Behavior:**
- Tries each strategy in sequence until one succeeds
- First success wins, remaining strategies skipped
- Fails only if ALL strategies fail

**Key Insight:** Warden is the foundational Rack authentication framework that both Devise (Rails) and other Ruby frameworks build upon. It was specifically designed with multiple strategy support from day one.

### 2. Django REST Framework (Python)

```python
# Multiple authentication classes tried in order
authentication_classes = [SessionAuthentication, TokenAuthentication, BasicAuthentication]

# "If one authentication class authenticates the user,
# all other classes are skipped"
```

**Behavior:**
- Order matters (first success wins)
- Use case: Support web browsers (session) AND API clients (token)

**Implementation Note:** Django REST Framework processes authentication classes sequentially. If any class successfully authenticates, the remaining classes are not processed. This is OR logic, not AND.

### 3. Passport.js (Node/Express)

```javascript
// Array of strategies with OR logic
app.post('/api/data',
  passport.authenticate(['local', 'bearer', 'oauth2']))

// "Will only fail if NONE of the strategies returned success"
```

**Behavior:**
- Explicit array syntax
- Commonly used for: session OR API key OR OAuth token

**Documentation:** Passport's official documentation emphasizes that passing multiple strategies creates an OR relationship, allowing requests to authenticate via any of the provided methods.

---

## Common Use Cases

### API Endpoints Supporting Multiple Client Types

```
GET /api/users   auth=session,apikey,oauth
```

**Scenario:**
- **Web browser:** Uses session cookies
- **Mobile app:** Uses API key
- **Third-party integration:** Uses OAuth token

**Why This Matters:** Modern applications often need to support multiple client types accessing the same resources. Requiring separate endpoints for each auth method breaks REST principles and creates maintenance overhead.

### Gradual Migration Patterns

```
GET /protected   auth=legacy,modern
```

**Scenario:**
- Support old auth method while migrating to new one
- Remove legacy strategy after migration complete

**Real-World Example:** Migrating from custom token auth to OAuth 2.0 without breaking existing integrations.

### Tiered Authentication

```
GET /public-data   auth=anonymous,session
```

**Scenario:**
- Anonymous users get rate-limited access
- Authenticated users get full access

**Use Case:** Public APIs that offer limited anonymous access but enhanced features for authenticated users.

---

## Best Practices vs Anti-Patterns

### ✅ Best Practices

#### 1. OR Logic, Not AND

Multiple strategies = "authenticate via ANY of these methods"

```
auth=session,apikey  # Session OR API key (not both)
```

**Rationale:** Authentication answers "WHO are you?" A user cannot be authenticated via multiple methods simultaneously in a meaningful way. They authenticate via ONE method that successfully proves their identity.

#### 2. Order Matters - Most Preferred First

```
auth=session,apikey,basic  # Try session first (stateful, faster)
```

**Performance Considerations:**
- **Session auth:** Cheapest (just session lookup in memory/Redis)
- **API key:** Medium cost (database lookup)
- **OAuth token:** Most expensive (signature verification, possible external validation)

**Security Note:** Put more secure/trusted methods first. If session authentication succeeds, you don't need to validate the API key.

#### 3. Separation of Authentication vs Authorization

- **Authentication:** WHO are you? (session, API key, OAuth)
- **Authorization:** WHAT can you do? (role, permission)

```
# Good: Clear separation
auth=session,apikey           # WHO (authentication)
role=admin                    # WHAT (authorization)

# Bad: Mixing concerns
auth=admin_session,user_apikey  # Conflates WHO and WHAT
```

**Why This Matters:** Authentication and authorization are orthogonal concerns. Mixing them creates maintenance problems and violates the Single Responsibility Principle.

#### 4. Explicit Failure Messages

```ruby
# Log which strategies were tried
"Authentication failed: tried [session, apikey, oauth], all failed"
```

**Debugging Value:** When authentication fails in production, knowing which strategies were attempted helps diagnose issues (expired tokens, missing headers, etc.).

#### 5. Content Negotiation

Some frameworks automatically choose strategy based on request headers:

```ruby
# If request has Authorization header → try token first
# If request has session cookie → try session first
```

**Advanced Pattern:** While not required, some implementations optimize by reordering strategies based on request characteristics.

### ❌ Anti-Patterns

#### 1. Requiring ALL Strategies to Pass (AND Logic)

```
# WRONG: Requiring both session AND API key
auth=session&apikey  # Makes no sense - that's not authentication
```

**Why This is Wrong:** This conflates authentication with authorization. If you need multiple verification factors, use Multi-Factor Authentication (MFA) within a single strategy, not multiple strategies.

**Correct Approach for MFA:**
```ruby
# ONE strategy that implements MFA internally
class MFAStrategy
  def authenticate(env, req)
    # Verify password (factor 1)
    # Verify TOTP code (factor 2)
    # Both must pass within this single strategy
  end
end
```

#### 2. Different Strategies Per Route for Same Resource

```
# WRONG: Inconsistent authentication
GET  /users   auth=session
POST /users   auth=apikey

# RIGHT: Consistent authentication
GET  /users   auth=session,apikey
POST /users   auth=session,apikey
```

**Why This is Wrong:** Different auth requirements for different HTTP methods on the same resource breaks client expectations and creates security confusion.

#### 3. Creating Composite Strategies Instead of Native Support

```ruby
# WORKAROUND (not ideal):
class SessionOrAPIKeyStrategy
  def authenticate(env, req)
    session_result = SessionStrategy.new.authenticate(env, req)
    return session_result if session_result.success?

    APIKeyStrategy.new.authenticate(env, req)
  end
end

otto.add_auth_strategy('session_or_apikey', SessionOrAPIKeyStrategy.new)

# Routes file
GET /api/data   auth=session_or_apikey

# BETTER: Native framework support
GET /api/data   auth=session,apikey
```

**Why This is Suboptimal:**
- Doesn't scale (need composite for each combination)
- Less clear in routes file (what strategies are included?)
- Harder to maintain (changing strategy order requires code changes)
- Not standard (other developers expect framework-level support)

#### 4. Mixing Authentication Strategies with Authorization Rules

```ruby
# WRONG: Conflating auth and authz
auth=admin_session  # This is authorization, not authentication!

# RIGHT: Separate concerns
auth=session
role=admin
```

**Why This is Wrong:** `admin_session` suggests that authentication depends on authorization. In reality, authentication establishes WHO you are, then authorization checks WHAT you can do.

**Correct Pattern:**
```
# Authenticate via session, then authorize admin role
GET /admin/dashboard   auth=session   role=admin
```

---

## OWASP & Security Considerations

### From OWASP Authentication Cheat Sheet

1. **Fail Securely:** If all strategies fail → deny access (401/403)
2. **Log Authentication Events:** Log which strategy succeeded
3. **Least Privilege:** Authentication ≠ Authorization
4. **Defense in Depth:** Multiple auth methods don't weaken security if implemented correctly

### Security Notes for Multiple Strategies

- ✅ **SAFE:** `auth=session,apikey` - Different auth methods for different clients
- ⚠️ **CAREFUL:** Order matters - put more secure methods first
- ❌ **DANGEROUS:** Fallback to weaker auth if stronger fails (e.g., `auth=mfa,basic` could bypass MFA)

### Dangerous Pattern Example

```
# DANGEROUS: Could allow MFA bypass
auth=mfa,basic

# If MFA fails, falls back to basic auth → defeats MFA purpose
```

**Safe Alternative:**
```
# Use MFA strategy only (no fallback)
auth=mfa

# Or separate routes for different security levels
GET /high-security   auth=mfa
GET /low-security    auth=basic
```

### Logging and Monitoring

**Essential Security Logs:**
```ruby
# Log successful authentication
Otto.structured_log(:info, "Authentication succeeded",
  strategy: 'apikey',
  strategies_tried: ['session', 'apikey'],
  user_id: result.user_id
)

# Log authentication failures
Otto.structured_log(:warn, "Authentication failed",
  strategies_tried: ['session', 'apikey', 'oauth'],
  ip: env['REMOTE_ADDR']  # Already masked by IPPrivacyMiddleware
)
```

**Why This Matters:**
- Detect authentication bypass attempts
- Identify broken integrations (clients using wrong auth method)
- Monitor for credential stuffing attacks

---

## Recommendation for Otto

### YES, Multiple Strategies is Reasonable and Recommended

Based on industry standards (Warden, DRF, Passport), Otto SHOULD support:

```
GET /api/data   auth=session,apikey,oauth
```

### Semantics

- **OR logic:** Authenticate via session OR API key OR OAuth
- **First success wins:** Once authenticated, stop trying strategies
- **Fail if all fail:** Return 401 only if ALL strategies fail
- **Order matters:** Try left-to-right (most preferred first)

### Why This is Better Than Alternatives

#### Alternative 1: Composite Strategies

```ruby
otto.add_auth_strategy('session_or_apikey', CompositeStrategy.new(session, apikey))
```

**Drawbacks:**
- ❌ Doesn't scale (need composite for each combination)
- ❌ Less clear in routes file
- ❌ Harder to maintain
- ❌ Not industry standard

#### Alternative 2: Multiple Routes

```
GET /api/data/session   auth=session
GET /api/data/apikey    auth=apikey
```

**Drawbacks:**
- ❌ Route explosion
- ❌ Breaks REST principles
- ❌ Client needs to know which endpoint to use
- ❌ Cache invalidation complexity (same resource, multiple URLs)

#### Recommended: Native Multi-Strategy Support

```
GET /api/data   auth=session,apikey
```

**Benefits:**
- ✅ Matches industry standards (Warden, DRF, Passport)
- ✅ Clear, concise syntax
- ✅ Flexible for clients (use whatever auth method they have)
- ✅ Easy to add/remove strategies
- ✅ Single endpoint per resource (REST compliant)

---

## Implementation Pattern (Following Warden)

### Proposed Route Parsing

```ruby
# lib/otto/route_definition.rb
def auth_requirements
  auth = option(:auth)
  return [] unless auth

  # Split on comma and strip whitespace
  auth.split(',').map(&:strip)
end

# Keep backward compatibility
def auth_requirement
  reqs = auth_requirements
  reqs.empty? ? nil : reqs.first
end
```

### Proposed Authentication Flow

```ruby
# lib/otto/security/authentication/route_auth_wrapper.rb
def call(env, extra_params = {})
  auth_requirements = route_definition.auth_requirements  # ['session', 'apikey']

  return anonymous_result if auth_requirements.empty?

  # Try each strategy in order (OR logic)
  auth_requirements.each do |requirement|
    strategy, strategy_name = get_strategy(requirement)
    next unless strategy  # Skip if not found

    result = strategy.authenticate(env, requirement)

    if result.success?
      # First success wins
      Otto.structured_log(:info, "Authentication succeeded",
        Otto::LoggingHelpers.request_context(env).merge(
          strategy: strategy_name,
          tried: auth_requirements,
          succeeded_with: strategy_name
        )
      )

      # Set env and return successful result
      env['otto.strategy_result'] = result
      env['otto.user'] = result.user_context
      env['rack.session'] = result.session_data if result.session_data
      return wrapped_handler.call(env, extra_params)
    end
  end

  # All strategies failed
  Otto.structured_log(:warn, "Authentication failed",
    Otto::LoggingHelpers.request_context(env).merge(
      strategies_tried: auth_requirements
    )
  )

  unauthorized_response(env, "Authentication required")
end
```

### Example Routes File

```
# Organization Management API
# Supports both browser sessions and API keys

GET    /orgs                    OrgAPI::ListOrgs    auth=session,apikey    response=json
POST   /orgs                    OrgAPI::CreateOrg   auth=session,apikey    response=json
GET    /orgs/:id                OrgAPI::GetOrg      auth=session,apikey    response=json
PUT    /orgs/:id                OrgAPI::UpdateOrg   auth=session,apikey    response=json
DELETE /orgs/:id                OrgAPI::DeleteOrg   auth=session,apikey    response=json

# Admin-only endpoints (session required for CSRF protection)
GET    /admin/dashboard         Admin::Dashboard    auth=session           role=admin
POST   /admin/users/:id/ban     Admin::BanUser      auth=session           role=admin

# Public API (anonymous or authenticated)
GET    /public/stats            Public::Stats       auth=anonymous,session response=json
```

### Testing Strategy

```ruby
# spec/otto/security/route_auth_wrapper_spec.rb
describe 'multiple auth strategies' do
  it 'succeeds if first strategy succeeds' do
    # auth=session,apikey - session succeeds
    expect(response.status).to eq(200)
    expect(logs).to include(strategy: 'session', succeeded_with: 'session')
  end

  it 'tries second strategy if first fails' do
    # auth=session,apikey - session fails, apikey succeeds
    expect(response.status).to eq(200)
    expect(logs).to include(strategy: 'apikey', tried: ['session', 'apikey'])
  end

  it 'fails if all strategies fail' do
    # auth=session,apikey - both fail
    expect(response.status).to eq(401)
    expect(logs).to include(strategies_tried: ['session', 'apikey'])
  end

  it 'respects strategy order' do
    # auth=apikey,session - tries apikey first
    expect(auth_attempts.first).to eq('apikey')
  end

  it 'handles missing strategies gracefully' do
    # auth=session,unknown - unknown strategy doesn't exist
    expect(response.status).to eq(200)  # session succeeds
    expect(logs).to include(strategy: 'session')
  end
end
```

---

## Summary

### Answer: YES, supporting multiple strategies is the industry-standard approach.

- ✅ Warden (Ruby/Rack reference impl) supports it
- ✅ Django REST Framework supports it
- ✅ Passport.js supports it
- ✅ OWASP doesn't flag concerns with proper implementation
- ✅ Common use case: Supporting multiple client types (web + mobile + API)
- ✅ Otto's architecture (strategy pattern) is already well-positioned for this

### Recommended Syntax

```
auth=session,apikey,oauth  # OR logic, left-to-right priority
```

### NOT Recommended

- Creating composite strategies for each combination
- Using route duplication
- Mixing authentication and authorization
- AND logic for multiple strategies
- Fallback to weaker auth methods

### Implementation Effort

**Files to Modify:**
1. `lib/otto/route_definition.rb` - Add `auth_requirements` method
2. `lib/otto/security/authentication/route_auth_wrapper.rb` - Update `call` to try multiple strategies
3. `spec/otto/security/route_auth_wrapper_spec.rb` - Add comprehensive tests

**Estimated Effort:** 4-6 hours including:
- Code changes (2 hours)
- Tests (2 hours)
- Edge case handling and documentation (1-2 hours)

**Complexity:** Medium - touches core authentication flow but well-isolated

---

## References

### Official Documentation
- [Warden README](https://github.com/wardencommunity/warden/wiki) - Ruby Rack authentication framework
- [Django REST Framework - Authentication](https://www.django-rest-framework.org/api-guide/authentication/)
- [Passport.js Documentation](https://www.passportjs.org/concepts/authentication/strategies/)
- [OWASP Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html)

### Key Insights from Research
- Devise (Rails' most popular auth library) is built on Warden
- Passport.js has 500+ authentication strategies available
- Django REST Framework's approach matches Warden's cascade pattern
- Industry consensus: Multiple strategies = OR logic, not AND

### Related Topics
- Multi-Factor Authentication (MFA) - Multiple factors within ONE strategy
- Content Negotiation - Automatic strategy selection based on headers
- Rate Limiting - Different limits per authentication method
- CORS - Pre-flight requests and authentication
