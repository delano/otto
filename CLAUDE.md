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

1. **Automatic Freezing**: `freeze_configuration!` is called automatically after initialization (unless in RSpec test environment)
2. **Deep Freezing**: Uses recursive freezing to prevent modification at any nesting level
3. **Memoization-Compatible**: Pre-computes memoized values before freezing to avoid FrozenError

### What Gets Frozen

- **Security Config**: All security settings including CSRF, validation, rate limiting, and headers
- **Middleware Stack**: Prevents adding, removing, or modifying middleware after initialization
- **Routes**: All route structures (`@routes`, `@routes_literal`, `@routes_static`, `@route_definitions`)
- **Configuration Hashes**: `@auth_config`, `@locale_config`, `@option` and all nested structures

### Security Guarantees

```ruby
# After initialization, ALL of these will raise FrozenError:

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

### Testing Considerations

- Freezing is **automatically disabled** when `RSpec` is defined
- For manual unfreezing in tests, use `Otto.unfreeze_for_testing(otto)` (requires RSpec to be defined)
- **Never** use `unfreeze_for_testing` in production code - it raises an error if RSpec is not defined

### Implementation Details

- `Otto::Core::Freezable` module provides `deep_freeze!` method
- `MiddlewareStack` and `Security::Config` override `deep_freeze!` to pre-compute memoized values
- Uses `defined?()` pattern instead of `||=` for freeze-compatible memoization
- All mutation methods check `frozen?` and raise `FrozenError` when frozen

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
