# Otto Security Features Example

This source-checkout example configures CSRF protection, request validation, request-size and parameter limits, trusted proxies, and response security headers. It provides forms for feedback, file-upload metadata, and profile input so you can observe those protections.

## Prerequisites

Run this example from an Otto source checkout. Its `config.ru` loads Otto from `../../lib`, rather than from an installed gem.

You need a supported Ruby version and Bundler. `rackup` is a development dependency in the root `Gemfile`, so enable the `development` group before installing dependencies:

```sh
# From the repository root
bundle config set with development
bundle install
```

## Run the example

```sh
# From the repository root
cd examples/security_features
bundle exec rackup config.ru -p 10770
```

Open `http://127.0.0.1:10770/`. Keep the server running and use a second terminal for the checks below.

## What this example configures

`config.ru` enables CSRF protection and request validation, then sets these limits:

- Maximum request size: 5 MiB
- Maximum parameter nesting depth: 10
- Maximum parameter keys: 50

It trusts the listed loopback and private-network proxy ranges. Adjust `trusted_proxies` for a real deployment; do not copy this development-oriented list without confirming the proxies that can reach your application.

Every route receives the configured headers:

- `Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'`
- `Strict-Transport-Security: max-age=31536000; includeSubDomains`
- `X-Frame-Options: DENY`

## Verify the protections

Use the diagnostic route to inspect request information and the response headers. A POST without a CSRF token exercises the CSRF rejection path:

```sh
curl -i http://127.0.0.1:10770/headers
curl -i -X POST http://127.0.0.1:10770/feedback -d 'message=test'
```

The feedback handler rejects script-like input and limits messages to 1,000 characters; profile fields have their own limits and the email field must match the example's basic format check. The upload form demonstrates filename sanitization and request handling. It displays metadata and does **not** permanently store uploaded files; it does not implement a file-type allowlist.

### Current limitation

The home page generates a CSRF token during its first request. Otto freezes configuration at that point, and the generated-secret warning then attempts to modify the frozen security configuration. As a result, `GET /` currently fails with `FrozenError`, so browser-based valid-form verification is unavailable until that example or the initialization sequence is corrected.

## Files to inspect

- `config.ru` creates the Otto application and sets the security configuration.
- `routes` defines the form and diagnostic endpoints.
- `app.rb` renders CSRF form fields and handles validation, escaped output, and uploaded-file metadata.

## Next steps

- See the [authentication strategies example](../authentication_strategies/README.md) for route authentication.
- Read the [security configuration in the main README](../../README.md#security-features).
