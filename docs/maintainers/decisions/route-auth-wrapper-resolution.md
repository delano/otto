# Post-Routing Authentication: RouteAuthWrapper Implementation

**Status**: ✅ Resolved in commit 6113b2a
**Date**: October 10, 2025
**Impact**: Security enhancement - proper enforcement of route-level authentication requirements

## Problem

Otto's original `AuthenticationMiddleware` had a fundamental architectural flaw that prevented route-level authentication enforcement:

### The Chicken-and-Egg Issue

```ruby
# Middleware runs BEFORE routing
AuthenticationMiddleware.call(env)
  route_definition = env['otto.route_definition']  # nil - not set yet!
  # Creates anonymous result and exits early
  # Auth strategies never execute

# Route sets definition DURING execution (too late)
Route#call(env)
  env['otto.route_definition'] = @route_definition  # Set here
```

**Flow**: `Middleware → [needs route_definition] → Router → [sets route_definition]`

### Security Impact

- Routes declared with `auth=sessionauth` were not enforced
- Protected routes like `/account` and `/dashboard` potentially accessible to anonymous users
- Auth strategies were registered but never executed
- Manual checks in application code were the only protection

## Solution: Post-Routing Authentication

Implemented **RouteAuthWrapper** pattern that executes authentication AFTER routing but BEFORE handler execution.

### Architecture

```
Request → Session Middleware → Router → HandlerFactory
                                          ↓
                                    RouteAuthWrapper
                                          ↓
                              [Execute Auth Strategy]
                                          ↓
                            Success ↓       ↓ Failure (401/302)
                                          ↓
                              Wrapped Handler
```

### Implementation

**1. RouteAuthWrapper** (`lib/otto/security/authentication/route_auth_wrapper.rb`)
```ruby
class RouteAuthWrapper
  def initialize(wrapped_handler, route_definition, auth_config, security_config = nil)
    @wrapped_handler  = wrapped_handler
    @route_definition = route_definition
    @auth_config      = auth_config
    @security_config  = security_config
    @strategy_cache   = {}  # Cache resolved strategies
  end

  def call(env, extra_params = {})
    # Route definition is available here (post-routing)
    auth_requirement = route_definition.auth_requirement
    strategy = get_strategy(auth_requirement)  # Uses caching + pattern matching

    # Execute authentication strategy
    result = strategy.authenticate(env, auth_requirement)

    # Set environment for controllers
    env['otto.strategy_result'] = result
    env['otto.user'] = result.user
    env['otto.user_context'] = result.user_context

    # Block on failure (401 JSON or 302 redirect with security headers)
    return auth_failure_response(env, result) if result.is_a?(FailureResult)

    # SESSION PERSISTENCE: Object identity critical for Rack session middleware
    env['rack.session'] = result.session if result.is_a?(StrategyResult) && result.session

    # Proceed on success
    wrapped_handler.call(env, extra_params)
  end
end
```

**2. HandlerFactory Integration** (`lib/otto/route_handlers/factory.rb:28-37`)
```ruby
def self.create_handler(route_definition, otto_instance = nil)
  handler = case route_definition.kind
            when :logic then LogicClassHandler.new(...)
            when :instance then InstanceMethodHandler.new(...)
            when :class then ClassMethodHandler.new(...)
            end

  # Wrap with auth enforcement if route requires it
  if route_definition.auth_requirement && otto_instance&.auth_config
    handler = RouteAuthWrapper.new(
      handler,
      route_definition,
      otto_instance.auth_config,
      otto_instance.security_config  # For security headers on auth failures
    )
  end

  handler
end
```

**3. Route Execution** (`lib/otto/route.rb:140-142`)
```ruby
def call(env, extra_params = {})
  # Set route definition before handler execution
  env['otto.route_definition'] = @route_definition

  # Use pluggable handler factory (includes auth wrapping)
  if otto&.route_handler_factory
    handler = otto.route_handler_factory.create_handler(@route_definition, otto)
    handler.call(env, extra_params)
  end
end
```

## Key Benefits

1. **Route Context Available**: Auth logic has access to route definition (requirement, options, params)
2. **Declarative Security**: Routes declare `auth=sessionauth`, enforcement is automatic
3. **Clean Separation**:
   - Otto provides auth primitives (strategies, results, wrapper)
   - Apps register strategies and declare requirements
   - Framework handles enforcement
4. **Backward Compatible**: Existing middleware approach still works for custom patterns

## Verification

Test results confirm protected routes are properly enforced:

```ruby
# Anonymous access to protected routes
GET /account   (auth=sessionauth) → 302 redirect ✅
GET /dashboard (auth=sessionauth) → 302 redirect ✅

# Public routes remain accessible
GET /          (auth=noauth)      → 200 OK ✅
```

## Files Changed

- `lib/otto/security/authentication/route_auth_wrapper.rb` (new)
- `lib/otto/route_handlers/factory.rb` (modified)
- `lib/otto/route.rb` (modified)
- `lib/otto.rb` (minor config)

## Usage Pattern

**Application Registration**:
```ruby
# Register strategies
otto.add_auth_strategy('noauth', NoAuthStrategy.new)
otto.add_auth_strategy('sessionauth', SessionAuthStrategy.new)

# Declare in routes file
GET /public   Controller#action auth=noauth
GET /private  Controller#action auth=sessionauth
```

**No additional configuration needed** - RouteAuthWrapper is automatically applied by the handler factory.

## Migration Notes

Applications using Otto's authentication should:
1. Remove calls to `otto.enable_authentication!` (no longer needed)
2. Continue registering strategies via `otto.add_auth_strategy`
3. Declare auth requirements in routes files
4. Trust that enforcement is automatic

The original `AuthenticationMiddleware` has been removed as it was fundamentally broken and non-functional.

---

**Resolution**: This issue documents the problem and its solution for historical reference. No further action required.
