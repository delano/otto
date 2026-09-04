# Otto Test Suite

This directory contains Otto's RSpec suite. It covers routing, request and
response handling, privacy, security configuration and middleware,
authentication and authorization, network-service integrations, and error
handling.

## Set up the test bundle

From the repository root, install the development and test dependencies. The
Gemfile marks these groups as optional, so enable them before installing:

```sh
bundle config set with 'development test'
bundle install
```

## Run tests

```sh
# Entire suite
bundle exec rspec

# A single file
bundle exec rspec spec/otto/security/csp_emission_integration_spec.rb

# A focused directory
bundle exec rspec spec/otto/security
```

To inspect a focused test with Otto debug logging:

```sh
OTTO_DEBUG=true bundle exec rspec spec/security_config_spec.rb --format documentation
```

## Test conventions

- Test observable behavior rather than private implementation details.
- Use Rack::Test for full request/response coverage where appropriate.
- Cover both route-level authentication/authorization and resource-level
  authorization.
- Verify configuration is complete before the first request, because Otto
  freezes configuration after that point.
- Exercise privacy and security boundaries, including malformed input, trusted
  proxies, and error responses.

See the [documentation map](../docs/README.md) for the current documentation
structure. Application-specific testing guidance is planned under `docs/guides/`.
