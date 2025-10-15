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
