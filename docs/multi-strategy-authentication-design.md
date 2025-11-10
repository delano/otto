# Multi-Strategy Authentication Design for Otto

**Date:** November 2025
**Status:** Design Document
**Related:** [Modern Authentication/Authorization Landscape](modern-authentication-authorization-landscape.md)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Implementation Patterns from Other Frameworks](#implementation-patterns-from-other-frameworks)
3. [Otto-Specific Design Decisions](#otto-specific-design-decisions)
4. [Auditing and Observability](#auditing-and-observability)
5. [Authorization Design](#authorization-design)
6. [Implementation Roadmap](#implementation-roadmap)

---

## Executive Summary

This document defines Otto's approach to supporting multiple authentication strategies per route, building on industry-standard patterns from Warden, Django REST Framework, and Passport.js.

**Key Decisions:**
- ✅ Support comma-separated strategies: `auth=session,apikey,oauth`
- ✅ OR logic: First success wins, fail only if all fail
- ✅ Explicit auditing via structured logging (no hooks system needed)
- ✅ Two-layer authorization: Route-level (authentication) + Resource-level (Logic classes)
- ✅ Maintain Otto's philosophy: Simple, explicit, secure by default

**Estimated Implementation:** 6-8 hours total
- Core multi-strategy support: 3-4 hours
- Auditing enhancements: 1-2 hours
- Authorization documentation: 2-3 hours

---

## Implementation Patterns from Other Frameworks

### Analysis of Framework Patterns

Based on research of Warden (Ruby/Rack), Django REST Framework (Python), and Passport.js (Node.js), here's what fits Otto's design philosophy:

#### 1. Strategy Validation Pattern (from Warden)

**Warden's Approach:**
```ruby
# Warden checks if strategy is "valid" before attempting authentication
class Strategy
  def valid?
    # Check if this strategy should be attempted for this request
    # E.g., check for Authorization header presence
  end

  def authenticate!
    # Only called if valid? returns true
  end
end
```

**Otto Fit:** ⚠️ **Partial** - Adds complexity
- **Pro:** Avoids unnecessary authentication attempts
- **Con:** Extra method to implement in every strategy
- **Decision:** Skip for v1, consider for v2 if performance issues arise

**Rationale:** Otto's strategies are already lightweight. Skipping invalid strategies adds minimal overhead compared to the complexity of implementing `valid?` checks.

---

#### 2. Strategy Ordering Pattern (from Django REST Framework)

**Django's Approach:**
```python
# authentication_classes tried in order, first success wins
authentication_classes = [SessionAuthentication, TokenAuthentication, BasicAuthentication]
```

**Otto Fit:** ✅ **EXCELLENT** - Direct match
- Aligns with Otto's route-based configuration
- Left-to-right order is intuitive
- No additional API needed

**Implementation:**
```ruby
# lib/otto/route_definition.rb
def auth_requirements
  auth = option(:auth)
  return [] unless auth

  auth.split(',').map(&:strip)  # "session,apikey" → ['session', 'apikey']
end
```

---

#### 3. Named Strategy Instances (from Passport.js)

**Passport's Approach:**
```javascript
// Create multiple instances of same strategy type with different configs
passport.use('user-local', new LocalStrategy(User.authenticate()));
passport.use('admin-local', new LocalStrategy(Admin.authenticate()));
```

**Otto Fit:** ✅ **ALREADY SUPPORTED** - No changes needed
- Otto already supports this via `add_auth_strategy(name, strategy)`
- Each strategy instance can have different configuration

**Example:**
```ruby
# Different session strategies for different user types
otto.add_auth_strategy('user_session', SessionStrategy.new(session_key: 'user_id'))
otto.add_auth_strategy('admin_session', SessionStrategy.new(session_key: 'admin_id'))

# Routes can choose which to use
GET /user/dashboard    auth=user_session
GET /admin/dashboard   auth=admin_session
```

---

#### 4. Session Control Pattern (from Passport.js)

**Passport's Approach:**
```javascript
// Control whether strategy creates a session
passport.authenticate('bearer', { session: false })
```

**Otto Fit:** ⚠️ **Not Applicable**
- Otto strategies return `StrategyResult` which contains session data
- Session management is handled by Rack session middleware
- Strategy doesn't control session creation

**Decision:** No changes needed - Otto's approach is architecturally superior (separation of concerns).

---

#### 5. Strategy Array Pattern (from Passport.js)

**Passport's Approach:**
```javascript
// Pass array of strategy names
app.post('/login', passport.authenticate(['local', 'bearer', 'oauth2']))
```

**Otto Fit:** ✅ **EXCELLENT** - Maps to comma-separated syntax
- Otto uses route file syntax, not code
- Comma separation is equivalent to array

**Otto Equivalent:**
```
POST /login   LoginController#create   auth=local,bearer,oauth2
```

---

### Patterns NOT Adopted

#### 1. Content Negotiation (Auto-Selection)

Some frameworks automatically reorder strategies based on request headers:

```ruby
# If request has Authorization header, try token auth first
# If request has session cookie, try session auth first
```

**Decision:** ❌ **Skip** - Too magical
- Violates Otto's "explicit over implicit" philosophy
- Makes debugging harder
- Developer should specify order in routes file

---

#### 2. Middleware-Based Authentication

**Passport/Express Pattern:**
```javascript
app.use(passport.initialize());
app.use(passport.session());
```

**Decision:** ✅ **Already Avoided** - Otto's architecture is superior
- Otto uses `RouteAuthWrapper` at correct layer (after routing, before handler)
- Middleware runs before routing (can't see route requirements)
- Otto's approach is what Rails community learned after years of trial

---

## Otto-Specific Design Decisions

### Core Implementation

#### Route Definition Parsing

**File:** `lib/otto/route_definition.rb`

```ruby
# Add new method for multiple auth requirements
def auth_requirements
  auth = option(:auth)
  return [] unless auth

  # Split on comma and strip whitespace
  # "session, apikey" → ['session', 'apikey']
  auth.split(',').map(&:strip)
end

# Keep backward compatibility - returns first requirement or nil
def auth_requirement
  reqs = auth_requirements
  reqs.empty? ? nil : reqs.first
end
```

**Rationale:**
- Backward compatible (existing code using `auth_requirement` still works)
- Simple parsing (no regex, no complex grammar)
- Clear intent (comma = OR logic)

---

#### Authentication Execution Flow

**File:** `lib/otto/security/authentication/route_auth_wrapper.rb`

```ruby
def call(env, extra_params = {})
  auth_requirements = route_definition.auth_requirements

  # No auth requirement → anonymous access
  if auth_requirements.empty?
    result = StrategyResult.anonymous(metadata: { ip: env['REMOTE_ADDR'] })
    env['otto.strategy_result'] = result
    return wrapped_handler.call(env, extra_params)
  end

  # Try each strategy in order (OR logic)
  tried_strategies = []

  auth_requirements.each do |requirement|
    strategy, strategy_name = get_strategy(requirement)

    # Skip if strategy not found (log warning but continue)
    unless strategy
      Otto.logger.warn "[RouteAuthWrapper] Strategy not found: #{requirement}"
      next
    end

    tried_strategies << strategy_name

    # Execute strategy
    start_time = Otto::Utils.now_in_μs
    result = strategy.authenticate(env, requirement)
    duration = Otto::Utils.now_in_μs - start_time

    # Inject strategy name into result
    result = result.with(strategy_name: strategy_name) if result.is_a?(StrategyResult)

    # SUCCESS: First success wins
    if result.is_a?(StrategyResult) && result.authenticated?
      Otto.structured_log(:info, "Authentication succeeded",
        Otto::LoggingHelpers.request_context(env).merge(
          strategy: strategy_name,
          strategies_tried: tried_strategies,
          succeeded_with: strategy_name,
          duration: duration
        )
      )

      env['otto.strategy_result'] = result
      env['otto.user'] = result.user_context
      env['rack.session'] = result.session if result.session

      return wrapped_handler.call(env, extra_params)
    end

    # FAILURE: Log and continue to next strategy
    Otto.structured_log(:debug, "Authentication failed",
      Otto::LoggingHelpers.request_context(env).merge(
        strategy: strategy_name,
        failure_reason: result.is_a?(AuthFailure) ? result.failure_reason : 'Unknown',
        duration: duration
      )
    )
  end

  # ALL STRATEGIES FAILED
  Otto.structured_log(:warn, "All authentication strategies failed",
    Otto::LoggingHelpers.request_context(env).merge(
      strategies_tried: tried_strategies,
      requirement: auth_requirements.join(',')
    )
  )

  unauthorized_response(env, "Authentication required")
end
```

**Key Design Points:**

1. **Graceful Degradation:** If a strategy isn't registered, log warning and try next
2. **First Success Wins:** Stop on first successful authentication
3. **Comprehensive Logging:** Log each attempt with timing
4. **Fail Securely:** Return 401 only if ALL strategies fail

---

#### Error Handling

**Missing Strategy Behavior:**

```ruby
# Route: auth=session,unknown,apikey
# Behavior:
# 1. Try 'session' → fails (not authenticated)
# 2. Try 'unknown' → warn and skip (strategy not registered)
# 3. Try 'apikey' → succeeds
# Result: 200 OK (authenticated via apikey)
```

**All Strategies Fail:**

```ruby
# Route: auth=session,apikey
# Behavior:
# 1. Try 'session' → fails
# 2. Try 'apikey' → fails
# Result: 401 Unauthorized
# Log: strategies_tried: ['session', 'apikey']
```

---

### Testing Strategy

**File:** `spec/otto/security/route_auth_wrapper_spec.rb`

```ruby
describe 'multiple authentication strategies' do
  let(:session_strategy) { double('SessionStrategy') }
  let(:apikey_strategy) { double('APIKeyStrategy') }

  before do
    otto.add_auth_strategy('session', session_strategy)
    otto.add_auth_strategy('apikey', apikey_strategy)
  end

  describe 'OR logic (first success wins)' do
    it 'succeeds if first strategy succeeds' do
      allow(session_strategy).to receive(:authenticate)
        .and_return(StrategyResult.new(user: user, session: {}, auth_method: 'session'))

      # Define route: auth=session,apikey
      get '/protected', {}, { 'HTTP_COOKIE' => 'session_id=abc123' }

      expect(last_response.status).to eq(200)
      expect(apikey_strategy).not_to have_received(:authenticate)  # Not called!
    end

    it 'tries second strategy if first fails' do
      allow(session_strategy).to receive(:authenticate)
        .and_return(AuthFailure.new(failure_reason: 'No session'))
      allow(apikey_strategy).to receive(:authenticate)
        .and_return(StrategyResult.new(user: user, session: {}, auth_method: 'apikey'))

      get '/protected', {}, { 'HTTP_AUTHORIZATION' => 'Bearer token123' }

      expect(last_response.status).to eq(200)
      expect(session_strategy).to have_received(:authenticate)
      expect(apikey_strategy).to have_received(:authenticate)
    end

    it 'fails if all strategies fail' do
      allow(session_strategy).to receive(:authenticate)
        .and_return(AuthFailure.new(failure_reason: 'No session'))
      allow(apikey_strategy).to receive(:authenticate)
        .and_return(AuthFailure.new(failure_reason: 'Invalid API key'))

      get '/protected'

      expect(last_response.status).to eq(401)
      expect(logs).to include(match(/All authentication strategies failed/))
    end
  end

  describe 'strategy order' do
    it 'tries strategies left-to-right' do
      execution_order = []

      allow(session_strategy).to receive(:authenticate) do
        execution_order << 'session'
        AuthFailure.new(failure_reason: 'No session')
      end

      allow(apikey_strategy).to receive(:authenticate) do
        execution_order << 'apikey'
        StrategyResult.new(user: user, session: {}, auth_method: 'apikey')
      end

      # Route: auth=session,apikey
      get '/protected'

      expect(execution_order).to eq(['session', 'apikey'])
    end
  end

  describe 'missing strategies' do
    it 'skips missing strategies and continues' do
      allow(session_strategy).to receive(:authenticate)
        .and_return(AuthFailure.new(failure_reason: 'No session'))

      # Route: auth=session,unknown,apikey (unknown doesn't exist)
      get '/protected'

      # Should warn about 'unknown' but still try 'apikey'
      expect(logs).to include(match(/Strategy not found: unknown/))
    end

    it 'fails if all valid strategies fail' do
      # Route: auth=unknown1,unknown2 (neither exists)
      get '/protected'

      expect(last_response.status).to eq(401)
    end
  end

  describe 'performance' do
    it 'stops on first success (does not try remaining strategies)' do
      expensive_strategy = double('ExpensiveStrategy')

      allow(session_strategy).to receive(:authenticate)
        .and_return(StrategyResult.new(user: user, session: {}, auth_method: 'session'))

      # Route: auth=session,expensive
      get '/protected'

      expect(expensive_strategy).not_to have_received(:authenticate)
    end
  end
end
```

---

## Auditing and Observability

### Current State Analysis

Otto already has excellent audit logging foundation:

1. **Structured Logging:** `Otto.structured_log` with consistent format
2. **Request Context:** `LoggingHelpers.request_context(env)` extracts core fields
3. **Timing Data:** Microsecond-precision timing via `Otto::Utils.now_in_μs`
4. **Privacy-Aware:** IPs already masked by `IPPrivacyMiddleware`

**What Otto Has (Already):**
```ruby
# Every authentication attempt is logged
Otto.structured_log(:info, "Auth strategy result",
  Otto::LoggingHelpers.request_context(env).merge(
    strategy: 'session',
    success: true,
    user_id: result.user_id,
    duration: 1234  # microseconds
  )
)
```

---

### Comparison with Rodauth's Audit Logging

**Rodauth's Approach:**
```ruby
# Rodauth uses hooks system
after_login do
  audit_log_action('login', user_id: account_id)
end

after_logout do
  audit_log_action('logout', user_id: account_id)
end
```

**Otto's Approach (Current):**
```ruby
# Otto uses structured logging directly in RouteAuthWrapper
Otto.structured_log(:info, "Authentication succeeded", {
  method: 'POST',
  path: '/login',
  strategy: 'session',
  user_id: result.user_id
})
```

**Comparison:**

| Aspect | Rodauth (Hooks) | Otto (Structured Logs) |
|--------|-----------------|------------------------|
| **Complexity** | Medium (hooks system) | Low (direct logging) |
| **Flexibility** | High (custom hooks) | Medium (log collectors) |
| **Performance** | Fast (in-process) | Fast (in-process) |
| **Separation** | Clear (hooks separate) | Excellent (logging concern) |
| **Testability** | Hard (hooks fire in tests) | Easy (mock logger) |
| **Storage** | Database table | Log aggregation system |

**Decision:** ✅ **Continue with structured logging** - No hooks system needed

**Rationale:**
- Otto's structured logging is simpler and more flexible
- Modern log aggregation (Datadog, Elasticsearch, Loki) handles storage
- Hooks add complexity without proportional benefit
- Structured logs are easier to test (mock logger vs mock hooks)

---

### Enhanced Auditing for Multi-Strategy Authentication

#### What to Log

**Authentication Attempt (All Strategies):**
```ruby
{
  event: "authentication_attempt",
  method: "POST",
  path: "/api/data",
  ip: "192.0.2.0",  # Already masked by IPPrivacyMiddleware
  country: "US",
  strategies_configured: ["session", "apikey", "oauth"],
  timestamp: "2025-11-08T23:00:00Z"
}
```

**Strategy Execution (Each Strategy):**
```ruby
{
  event: "strategy_executed",
  strategy: "session",
  success: false,
  failure_reason: "No session cookie",
  duration: 120,  # microseconds
  ip: "192.0.2.0",
  timestamp: "2025-11-08T23:00:00.000120Z"
}
```

**Authentication Success:**
```ruby
{
  event: "authentication_succeeded",
  strategy: "apikey",
  strategies_tried: ["session", "apikey"],
  user_id: "user_12345",
  duration_total: 1234,  # Total time across all strategies
  ip: "192.0.2.0",
  country: "US",
  timestamp: "2025-11-08T23:00:00.001234Z"
}
```

**Authentication Failure (All Failed):**
```ruby
{
  event: "authentication_failed",
  strategies_tried: ["session", "apikey", "oauth"],
  failure_reasons: {
    session: "No session cookie",
    apikey: "Invalid API key",
    oauth: "Token expired"
  },
  duration_total: 2345,
  ip: "192.0.2.0",
  country: "US",
  timestamp: "2025-11-08T23:00:00.002345Z"
}
```

---

#### Implementation: Audit Log Aggregation

**File:** `lib/otto/security/authentication/audit_logger.rb` (NEW)

```ruby
# lib/otto/security/authentication/audit_logger.rb
#
# frozen_string_literal: true

class Otto
  module Security
    module Authentication
      # Audit logger for authentication events
      #
      # Provides centralized audit logging for authentication attempts,
      # successes, and failures. Integrates with Otto's structured logging.
      #
      # @example Enable detailed audit logging
      #   Otto.enable_auth_audit_logging!
      #
      class AuditLogger
        class << self
          # Log authentication attempt start
          def log_attempt(env, strategies)
            return unless Otto.auth_audit_logging_enabled?

            Otto.structured_log(:info, "Authentication attempt",
              Otto::LoggingHelpers.request_context(env).merge(
                event: 'authentication_attempt',
                strategies_configured: strategies
              )
            )
          end

          # Log individual strategy execution
          def log_strategy_execution(env, strategy_name, result, duration)
            return unless Otto.auth_audit_logging_enabled?

            event_data = Otto::LoggingHelpers.request_context(env).merge(
              event: 'strategy_executed',
              strategy: strategy_name,
              duration: duration
            )

            if result.is_a?(StrategyResult) && result.authenticated?
              event_data.merge!(success: true, user_id: result.user_id)
            else
              event_data.merge!(
                success: false,
                failure_reason: result.is_a?(AuthFailure) ? result.failure_reason : 'Unknown'
              )
            end

            Otto.structured_log(:info, "Strategy executed", event_data)
          end

          # Log authentication success
          def log_success(env, strategy_name, strategies_tried, user_id, duration_total)
            Otto.structured_log(:info, "Authentication succeeded",
              Otto::LoggingHelpers.request_context(env).merge(
                event: 'authentication_succeeded',
                strategy: strategy_name,
                strategies_tried: strategies_tried,
                user_id: user_id,
                duration_total: duration_total
              )
            )
          end

          # Log authentication failure
          def log_failure(env, strategies_tried, failure_reasons, duration_total)
            Otto.structured_log(:warn, "Authentication failed",
              Otto::LoggingHelpers.request_context(env).merge(
                event: 'authentication_failed',
                strategies_tried: strategies_tried,
                failure_reasons: failure_reasons,
                duration_total: duration_total
              )
            )
          end
        end
      end
    end
  end
end
```

**Configuration:**

```ruby
# lib/otto.rb
class Otto
  class << self
    attr_accessor :auth_audit_logging_enabled

    def enable_auth_audit_logging!
      @auth_audit_logging_enabled = true
    end

    def disable_auth_audit_logging!
      @auth_audit_logging_enabled = false
    end

    def auth_audit_logging_enabled?
      @auth_audit_logging_enabled ||= false
    end
  end
end
```

**Usage:**

```ruby
# In application initialization
Otto.enable_auth_audit_logging!

# Now all authentication attempts are logged with full details
# Logs go to Otto.logger (can be sent to Datadog, Elasticsearch, etc.)
```

---

#### Audit Log Analysis

**Example Log Aggregation Query (Elasticsearch/Datadog):**

```
# Failed login attempts by IP (potential brute force)
event:authentication_failed
| stats count by ip
| where count > 10
| sort -count

# Strategy effectiveness (which strategies succeed most)
event:authentication_succeeded
| stats count by strategy
| sort -count

# Authentication latency by strategy
event:strategy_executed AND success:true
| stats avg(duration) by strategy

# Geographic distribution of auth failures
event:authentication_failed
| stats count by country
| geotable
```

---

### Hooks vs Structured Logging: Decision Matrix

| Requirement | Hooks System | Structured Logging | Winner |
|-------------|--------------|-------------------|--------|
| **Audit trail** | ✅ Yes | ✅ Yes | **TIE** |
| **Custom actions** | ✅ Easy | ⚠️ Harder | Hooks |
| **Database storage** | ✅ Built-in | ❌ Manual | Hooks |
| **Log aggregation** | ❌ Manual | ✅ Built-in | **Logs** |
| **Simplicity** | ❌ Complex | ✅ Simple | **Logs** |
| **Testability** | ❌ Hard | ✅ Easy | **Logs** |
| **Performance** | ✅ Fast | ✅ Fast | **TIE** |
| **Compliance (GDPR)** | ⚠️ Careful | ✅ Easy | **Logs** |

**Decision:** ✅ **Structured Logging Wins** for Otto

**Rationale:**
1. Simpler to implement and maintain
2. Better testability (mock logger, not hooks)
3. Works with modern log aggregation (Datadog, Loki, Elasticsearch)
4. Privacy-aware by default (IPs already masked)
5. Hooks can be added later if needed (non-breaking)

**Optional Enhancement:** Provide example integration for log → database
```ruby
# examples/audit_logging_to_database.rb
# Shows how to consume Otto logs and store in database
```

---

## Authorization Design

### The Two-Layer Authorization Pattern

**Industry Best Practice:** Authorization requires TWO distinct layers:

#### Layer 1: Route-Level Authorization (Authentication)
- **Question:** Is user allowed to access THIS ROUTE?
- **Location:** `RouteAuthWrapper` (before handler execution)
- **Checks:** Authentication status, general roles/permissions
- **Speed:** Fast (no resource loading required)
- **Response:** 401/403 before handler runs
- **Examples:**
  - "Must be authenticated"
  - "Must have 'admin' role"
  - "Must have 'write' permission"

#### Layer 2: Resource-Level Authorization
- **Question:** Is user allowed to access THIS SPECIFIC RESOURCE?
- **Location:** Logic classes (in `raise_concerns` method)
- **Checks:** Ownership, relationships, resource attributes
- **Speed:** Slower (requires loading resource from database)
- **Response:** Raise `AuthorizationError` → 403
- **Examples:**
  - "User must own this post"
  - "User must be member of this organization"
  - "Post must not be archived"

---

### Current State: Otto Already Has This!

**Otto's architecture is already correct:**

```ruby
# Layer 1: Route-level (RouteAuthWrapper)
GET /posts/:id   PostLogic#show   auth=session

# Layer 2: Resource-level (Logic class)
class PostLogic
  def raise_concerns
    @post = Post.find(@params[:id])

    # Route auth guarantees: @context.authenticated? == true
    # Now check: can THIS user access THIS post?
    unless @context.user_id == @post.user_id || @context.has_role?('admin')
      raise Otto::AuthorizationError, "Cannot view another user's post"
    end
  end

  def process
    { post: @post }
  end
end
```

**What's Missing:** Documentation and `AuthorizationError` class

---

### Evaluating `role=` Syntax in Routes

#### Current Capability: Role-Based Authentication

Otto currently supports role checking via `RoleStrategy`:

```ruby
# Register role strategy
otto.add_auth_strategy('role', RoleStrategy.new(['admin', 'moderator']))

# Route with role requirement
GET /admin   AdminPanel#index   auth=role:admin
```

**How it works:**
1. `RoleStrategy` checks if user has required role in session
2. Returns `StrategyResult` if user has role
3. Returns `AuthFailure` if user lacks role
4. Same authentication flow as other strategies

---

#### Proposed: `role=` as Separate Route Parameter

**Syntax:**
```
GET /admin   AdminPanel#index   auth=session   role=admin
```

**Pros:**
- ✅ Clearer separation (authentication vs authorization)
- ✅ Can combine with multi-strategy auth: `auth=session,apikey role=admin`
- ✅ More explicit (easier to audit routes file)

**Cons:**
- ❌ Requires new parsing logic in `RouteDefinition`
- ❌ Requires new enforcement logic in `RouteAuthWrapper`
- ❌ Can already be done with `auth=role:admin`

**Analysis:**

| Approach | Syntax | Separation | Implementation |
|----------|--------|------------|----------------|
| **Current** | `auth=role:admin` | ⚠️ Blurred | ✅ Already works |
| **Proposed** | `auth=session role=admin` | ✅ Clear | ❌ Needs work |

**Decision:** ⚠️ **DEFER** - Current approach works, new syntax is marginal improvement

**Rationale:**
1. Current `auth=role:admin` works fine
2. For complex authorization, use Logic classes (Layer 2)
3. Route-level authorization should be simple
4. Can add `role=` syntax later if demand emerges (non-breaking)

---

### Recommended Authorization Patterns

#### Pattern 1: Route Protection Only (Layer 1)

**Use Case:** Admin panel, no resource-specific checks

```ruby
# routes.txt
GET /admin/dashboard   Admin::Dashboard#index   auth=session,apikey   role=admin

# Logic class (minimal)
class Admin::Dashboard
  def raise_concerns
    # No additional checks - route auth handles everything
  end

  def process
    # Guaranteed: user is authenticated AND has admin role
    { stats: gather_stats }
  end
end
```

---

#### Pattern 2: Ownership Check (Layer 2)

**Use Case:** User editing own profile/posts

```ruby
# routes.txt
PUT /posts/:id   Post::Update#call   auth=session,apikey

# Logic class
class Post::Update
  def raise_concerns
    @post = Post.find(@params[:id])

    # Layer 1 guaranteed: user is authenticated
    # Layer 2 check: does user own this post?
    unless @context.user_id == @post.user_id
      raise Otto::AuthorizationError, "Cannot edit another user's post"
    end
  end

  def process
    @post.update(title: @params[:title])
    { post: @post }
  end
end
```

---

#### Pattern 3: Complex Multi-Condition Authorization

**Use Case:** Organization membership + role

```ruby
# routes.txt
DELETE /orgs/:org_id/members/:member_id   Org::RemoveMember#call   auth=session

# Logic class
class Org::RemoveMember
  def raise_concerns
    @org = Organization.find(@params[:org_id])
    @member = User.find(@params[:member_id])

    # Check 1: User must be org owner OR have 'admin' role
    is_owner = @org.owner_id == @context.user_id
    is_admin = @context.has_role?('admin')

    unless is_owner || is_admin
      raise Otto::AuthorizationError, "Must be organization owner or admin"
    end

    # Check 2: Cannot remove yourself
    if @member.id == @context.user_id
      raise Otto::AuthorizationError, "Cannot remove yourself from organization"
    end

    # Check 3: Cannot remove other admins unless you're owner
    if @member.has_role?('admin') && !is_owner
      raise Otto::AuthorizationError, "Only owner can remove admins"
    end
  end

  def process
    @org.remove_member(@member)
    { success: true }
  end
end
```

---

#### Pattern 4: Scoped Resource Access

**Use Case:** List only user's own resources

```ruby
# routes.txt
GET /posts   Post::List#call   auth=session,apikey

# Logic class
class Post::List
  def raise_concerns
    # No authorization errors - we just scope the results
  end

  def process
    # Return only posts user owns OR is public
    posts = if @context.has_role?('admin')
              Post.all  # Admins see everything
            else
              Post.where(user_id: @context.user_id)
                  .or(Post.where(public: true))
            end

    { posts: posts }
  end
end
```

---

### AuthorizationError Implementation

**File:** `lib/otto/security/authorization_error.rb` (NEW)

```ruby
# lib/otto/security/authorization_error.rb
#
# frozen_string_literal: true

class Otto
  module Security
    # Raised when user is authenticated but lacks authorization for resource
    #
    # Use this in Logic classes to indicate authorization failures.
    # Otto automatically converts this to 403 Forbidden response.
    #
    # @example In Logic class
    #   class Post::Update
    #     def raise_concerns
    #       unless @context.user_id == @post.user_id
    #         raise Otto::Security::AuthorizationError, "Cannot edit another user's post"
    #       end
    #     end
    #   end
    #
    class AuthorizationError < StandardError
      attr_reader :resource, :action, :user_id

      def initialize(message, resource: nil, action: nil, user_id: nil)
        super(message)
        @resource = resource
        @action = action
        @user_id = user_id
      end
    end
  end
end
```

**Register Error Handler:**

```ruby
# lib/otto.rb (in initialize)
def initialize(routes_source = nil, base_path: Dir.pwd)
  # ... existing initialization ...

  # Register authorization error handler
  register_error_handler(Otto::Security::AuthorizationError,
                        status: 403,
                        log_level: :warn) do |error, req|
    {
      error: 'Forbidden',
      message: error.message,
      resource: error.resource,
      action: error.action
    }
  end
end
```

---

### Authorization Anti-Patterns

#### ❌ Anti-Pattern 1: Authorization in Routes File

```ruby
# BAD: Complex authorization in routes
GET /posts/:id   Post::Show#call   auth=session,apikey   role=admin,moderator   owner_or_public=true

# This is too complex for routes - use Logic class instead
```

**Why Bad:** Routes should declare simple requirements, not complex business logic.

---

#### ❌ Anti-Pattern 2: No Layer 2 Authorization

```ruby
# BAD: Only route-level auth, no resource check
GET /posts/:id   Post::Show#call   auth=session

class Post::Show
  def raise_concerns
    # MISSING: No check if user can view THIS post
  end

  def process
    @post = Post.find(@params[:id])  # Any authenticated user can view any post!
    { post: @post }
  end
end
```

**Why Bad:** Authenticated doesn't mean authorized for specific resource.

---

#### ❌ Anti-Pattern 3: Authorization Without Authentication

```ruby
# BAD: Checking ownership without requiring authentication
GET /posts/:id   Post::Show#call   # No auth requirement!

class Post::Show
  def raise_concerns
    @post = Post.find(@params[:id])
    unless @context.user_id == @post.user_id  # @context.user_id could be nil!
      raise Otto::Security::AuthorizationError, "Cannot view"
    end
  end
end
```

**Why Bad:** `@context.user_id` is nil for unauthenticated users, causing errors or bypasses.

**Fix:** Always require authentication if doing authorization checks:
```
GET /posts/:id   Post::Show#call   auth=session,apikey
```

---

## Implementation Roadmap

### Phase 1: Core Multi-Strategy Support (3-4 hours)

**Files to Modify:**

1. **lib/otto/route_definition.rb**
   - Add `auth_requirements` method (returns array)
   - Keep `auth_requirement` for backward compatibility

2. **lib/otto/security/authentication/route_auth_wrapper.rb**
   - Update `call` method to loop through strategies
   - Add timing and logging for each attempt
   - Implement first-success-wins logic

3. **spec/otto/security/route_auth_wrapper_spec.rb**
   - Add tests for multiple strategies
   - Test OR logic (first success wins)
   - Test strategy ordering
   - Test missing strategy handling
   - Test failure logging

**Deliverables:**
- ✅ Routes support `auth=session,apikey,oauth` syntax
- ✅ First successful strategy wins
- ✅ Comprehensive logging
- ✅ Full test coverage

---

### Phase 2: Enhanced Auditing (1-2 hours)

**Files to Create:**

1. **lib/otto/security/authentication/audit_logger.rb**
   - Centralized audit logging methods
   - Integration with structured logging
   - Optional detailed mode

**Files to Modify:**

2. **lib/otto.rb**
   - Add `enable_auth_audit_logging!` method
   - Add configuration flag

3. **lib/otto/security/authentication/route_auth_wrapper.rb**
   - Integrate `AuditLogger` calls
   - Collect failure reasons from all strategies

**Deliverables:**
- ✅ Optional detailed audit logging
- ✅ Configuration API
- ✅ Example log aggregation queries

---

### Phase 3: Authorization Support (2-3 hours)

**Files to Create:**

1. **lib/otto/security/authorization_error.rb**
   - Define `AuthorizationError` exception
   - Include resource/action metadata

**Files to Modify:**

2. **lib/otto.rb**
   - Register `AuthorizationError` handler (403 response)

3. **CLAUDE.md**
   - Add Authorization section
   - Document two-layer pattern
   - Provide examples

**Files to Create (Documentation):**

4. **docs/authorization-patterns.md**
   - Comprehensive authorization guide
   - 5 common patterns with code
   - Anti-patterns to avoid

5. **examples/authorization/**
   - `ownership_check.rb`
   - `multi_condition.rb`
   - `resource_scoping.rb`

**Deliverables:**
- ✅ `AuthorizationError` exception
- ✅ Automatic 403 handling
- ✅ Comprehensive documentation
- ✅ Working examples

---

### Phase 4: Documentation & Polish (1-2 hours)

**Files to Modify:**

1. **CLAUDE.md**
   - Update Authentication section for multi-strategy
   - Add examples of `auth=session,apikey`
   - Link to new docs

2. **README.md** (if exists)
   - Update authentication examples
   - Add multi-strategy showcase

**Files to Create:**

3. **docs/authentication-strategies.md**
   - Complete strategy guide
   - How to create custom strategies
   - Multi-strategy best practices

4. **changelog.d/YYYYMMDD_multi_strategy_auth.rst**
   - Document new feature
   - Include examples
   - Note backward compatibility

**Deliverables:**
- ✅ Updated documentation
- ✅ Changelog entry
- ✅ Example applications

---

## Summary & Next Steps

### Key Decisions Made

1. ✅ **Multi-Strategy Syntax:** `auth=session,apikey,oauth` (comma-separated)
2. ✅ **OR Logic:** First success wins, fail only if all fail
3. ✅ **No Hooks System:** Structured logging is sufficient for auditing
4. ✅ **Authorization:** Two-layer pattern (route + Logic class)
5. ✅ **No `role=` syntax (yet):** Current `auth=role:admin` works fine

### What Otto Gains

**For Developers:**
- Support multiple client types (web + mobile + API) on same route
- Gradual migration between auth methods
- Clear separation of authentication and authorization
- Comprehensive audit trail via logs

**For Security:**
- Explicit authentication requirements in routes file
- Privacy-aware logging (IPs already masked)
- Resource-level authorization enforcement
- Fail-secure by default

**For Operations:**
- Structured logs integrate with log aggregation
- Performance metrics per strategy
- Authentication success/failure analytics
- Geographic distribution tracking

### Implementation Estimate

**Total Effort:** 6-8 hours
- Phase 1 (Core): 3-4 hours
- Phase 2 (Auditing): 1-2 hours
- Phase 3 (Authorization): 2-3 hours
- Phase 4 (Docs): 1-2 hours

**Complexity:** Medium
- Well-isolated changes
- Clear architecture
- Existing patterns to follow

### Recommended Next Steps

1. **Review & Approve Design** (this document)
2. **Implement Phase 1** (core multi-strategy support)
3. **Test with Real Application** (validate approach)
4. **Implement Phases 2-4** (auditing, authorization, docs)
5. **Ship & Iterate** (gather feedback)

---

## Appendix: Code Snippets

### Complete Example: Organization API with Multi-Strategy Auth

**routes.txt:**
```
# Organization Management API
# Supports browser sessions and API keys

GET    /orgs                    Org::List#call      auth=session,apikey    response=json
POST   /orgs                    Org::Create#call    auth=session,apikey    response=json
GET    /orgs/:id                Org::Show#call      auth=session,apikey    response=json
PUT    /orgs/:id                Org::Update#call    auth=session,apikey    response=json
DELETE /orgs/:id                Org::Delete#call    auth=session,apikey    response=json

# Admin only (session required for CSRF protection)
GET    /admin/orgs              Admin::Orgs#index   auth=session   role=admin
```

**app.rb:**
```ruby
require 'otto'

class OrganizationAPI < Otto
  def initialize
    super('routes.txt')

    # Configure authentication strategies
    add_auth_strategy('session', SessionStrategy.new(session_key: 'user_id'))
    add_auth_strategy('apikey', APIKeyStrategy.new)
    add_auth_strategy('role', RoleStrategy.new(['admin']))

    # Enable audit logging
    Otto.enable_auth_audit_logging!

    # Register authorization error handler (automatic 403)
    register_error_handler(Otto::Security::AuthorizationError, status: 403, log_level: :warn)
  end
end
```

**Logic class with authorization:**
```ruby
# app/logic/org/update.rb
module Org
  class Update
    def initialize(context, params)
      @context = context
      @params = params
    end

    def raise_concerns
      @org = Organization.find(@params[:id])

      # Layer 1: Route auth guaranteed user is authenticated
      # Layer 2: Check if user can edit THIS org
      unless can_edit_org?(@org)
        raise Otto::Security::AuthorizationError.new(
          "Cannot edit organization",
          resource: "Organization:#{@org.id}",
          action: "update",
          user_id: @context.user_id
        )
      end
    end

    def process
      @org.update(name: @params[:name])
      { organization: @org }
    end

    private

    def can_edit_org?(org)
      # Owner can edit
      return true if org.owner_id == @context.user_id

      # Admins can edit
      return true if @context.has_role?('admin')

      # Members with 'write' permission can edit
      return true if org.member?(@context.user_id) && @context.has_permission?('write')

      false
    end
  end
end
```

**Result:**
- Web browsers use session authentication
- Mobile apps use API key authentication
- Same route, different auth methods
- Resource-level authorization in Logic class
- Comprehensive audit trail via logs
