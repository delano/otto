# Configuration freezing

Otto supports multi-step boot configuration. In normal operation, it freezes the
configured application immediately before processing the first request. When
`RSpec` is defined, automatic request-time freezing is skipped so test suites can
assemble applications incrementally.

Configuration must be complete before traffic reaches the application. For a
more explicit boot boundary, call `freeze_configuration!` after setup and before
starting the Rack server.

## Configure before serving requests

```ruby
otto = Otto.new('routes.txt')

otto.add_auth_strategy(
  'session',
  Otto::Security::Authentication::Strategies::SessionStrategy.new(
    session_key: 'user_id'
  )
)
otto.add_auth_strategy(
  'api_key',
  Otto::Security::Authentication::Strategies::APIKeyStrategy.new(
    api_keys: ENV.fetch('API_KEYS').split(',')
  )
)
otto.enable_csrf_protection!
otto.use MyApp::Middleware
otto.register_error_handler(MyApp::NotFound, status: 404, log_level: :info)

# Optional: make the end of boot explicit rather than waiting for a request.
otto.freeze_configuration!
```

Calling a supported configuration method after freezing raises `FrozenError`:

```ruby
otto.add_auth_strategy('other', MyApp::OtherStrategy.new)
# FrozenError: Cannot modify frozen configuration
```

`freeze_configuration!` is idempotent and returns the Otto instance.

## What is frozen

`freeze_configuration!` freezes these owned structures:

- security and locale configuration objects;
- the middleware stack;
- authentication configuration and instance options;
- dynamic and literal route tables;
- route definitions and reverse-route indexes.

Hashes and arrays inside those structures are recursively frozen. Configuration
objects that implement `deep_freeze!` can prepare memoized values before they
are frozen.

The static-file route structure is an intentional exception. Its outer hash is
frozen, but the `routes_static[:GET]` `Concurrent::Map` remains writable because
Otto caches newly discovered static paths during requests.

## Scope and current limitations

Freezing is a guard around Otto's supported configuration APIs, not a complete
object-capability boundary. In particular, the current implementation exposes
some state that is not included in `freeze_configuration!`:

- `error_handlers` remains a mutable Hash, although
  `register_error_handler` rejects calls after freezing;
- the `not_found` and `server_error` fallback response writers remain available;
- the inner static-file cache remains mutable by design.

Application code should not mutate those objects directly after boot. Do not
state or depend on a guarantee that every object reachable from an Otto instance
is deeply immutable.

## Expected failures after freezing

These supported mutation paths reject changes after the freeze boundary:

```ruby
# Security configuration
otto.disable_csrf_protection!
otto.add_trusted_proxy('192.0.2.10')
otto.add_rate_limit_rule('uploads', limit: 5, period: 60)

# Middleware and authentication
otto.use MyApp::OtherMiddleware
otto.add_auth_strategy('other', MyApp::OtherStrategy.new)

# Helpers and expected-error handling
otto.register_request_helpers(MyApp::RequestHelpers)
otto.register_response_helpers(MyApp::ResponseHelpers)
otto.register_error_handler(MyApp::RateLimited, status: 429)
```

Direct mutation of frozen nested structures also raises `FrozenError`:

```ruby
otto.security_config.rate_limiting_config[:custom_rules] = {}
otto.auth_config[:auth_strategies] = {}
otto.routes[:GET] = []
```

## Testing the boundary

Otto deliberately skips automatic first-request freezing when `RSpec` is
defined. A freeze-focused spec must freeze explicitly:

```ruby
RSpec.describe 'configuration freezing' do
  it 'rejects configuration changes after the boot boundary' do
    otto = Otto.new
    otto.freeze_configuration!

    expect(otto.frozen_configuration?).to be(true)
    expect {
      otto.add_auth_strategy('other', MyApp::OtherStrategy.new)
    }.to raise_error(FrozenError, /Cannot modify frozen configuration/)
  end
end
```

Use a fresh Otto instance when a later example needs mutable configuration.
`Otto.unfreeze_for_testing` is an internal test helper that only resets the
`@configuration_frozen` flag; it cannot unfreeze Ruby objects that were already
frozen by `freeze_configuration!`.

## Thread behavior

For the automatic production path, `Otto#call` guards the first freeze with a
mutex and checks the frozen flag again inside the critical section. Concurrent
first requests therefore do not run the freeze operation concurrently.

## Related source and tests

- [`Otto#call`](../../lib/otto.rb) — automatic first-request boundary and the
  RSpec exception.
- [`Otto::Core::Configuration`](../../lib/otto/core/configuration.rb) — exact
  freeze scope and mutation guard.
- [`Otto::Core::Freezable`](../../lib/otto/core/freezable.rb) — recursive
  freezing behavior.
- [Configuration-freezing specs](../../spec/otto/configuration_freezing_spec.rb).
- [Static-file freezing specs](../../spec/otto/static_file_freezing_spec.rb).
