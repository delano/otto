# Otto Authentication Strategies Example

This source-checkout example shows four route-level authentication strategies:

- `authenticated` accepts `demo_token`.
- `role:admin` accepts `admin_token`.
- `permission:write` accepts `demo_token` or `admin_token`.
- `api_key` accepts `demo_api_key_123`.

The strategies are registered in `app/auth.rb` before the application handles its first request. The protected routes are defined in `routes`.

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
cd examples/authentication_strategies
bundle exec rackup config.ru
```

The server listens on `http://127.0.0.1:9292` by default. Leave it running and use a second terminal for the checks below.

## Verify the configured credentials

The strategies read the token from the query string or the exact `Authorization` header value. The API-key strategy reads the key from the query string or `X-API-Key`:

```sh
curl -i "http://127.0.0.1:9292/profile?token=demo_token"
curl -i -H 'Authorization: demo_token' http://127.0.0.1:9292/profile
curl -i "http://127.0.0.1:9292/api/data?api_key=demo_api_key_123"
curl -i -H 'X-API-Key: demo_api_key_123' http://127.0.0.1:9292/api/data
```

Use an omitted or invalid credential to exercise the authentication-failure path:

```sh
curl -i http://127.0.0.1:9292/profile
curl -i "http://127.0.0.1:9292/api/data?api_key=invalid"
```

### Current limitation

In this checkout, `app/controllers/main_controller.rb` and `app/controllers/auth_controller.rb` define class methods, while Otto instantiates route handlers with a request and response. Requests that reach those handlers therefore fail with an argument error. The commands above document the configured credential inputs, but they cannot currently verify a successful protected response until the controllers are made compatible with the handler interface.

## Files to inspect

- `config.ru` creates the Otto application, enables CSRF and request validation, and registers the strategies.
- `app/auth.rb` contains the demo credentials and strategy callbacks.
- `routes` associates each protected route with its `auth=` requirement.
- `app/controllers/auth_controller.rb` supplies the protected responses.

## Next steps

- See the [security features example](../security_features/README.md) for CSRF and request-validation configuration.
- Read [authentication documentation](../../docs/authentication.md) for application authentication design.
