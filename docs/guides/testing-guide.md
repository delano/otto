# Testing Otto applications

This guide covers the smallest useful testing workflow for an Otto application.
It favors requests through a real `Otto` instance and links to Otto's maintained
specs for implementation-level details.

## Prerequisites and commands

Otto supports Ruby `>= 3.2, < 4.1`. From an Otto source checkout, enable the
optional development and test groups before installing dependencies:

```sh
bundle config set --local with 'development test'
bundle install
bundle exec rspec
```

Run one file while developing:

```sh
bundle exec rspec spec/otto/security/route_auth_wrapper_spec.rb
```

The root `Rakefile` also makes `bundle exec rake` run the specs when RSpec is
installed. Otto's CI runs `bundle exec rspec`; use that command when checking the
same test entry point locally.

Applications consuming Otto need RSpec and `rack-test` in their own test bundle
if they use the examples below.

## Minimal test setup

Use Rack's environment builder rather than constructing partial Rack hashes by
hand:

```ruby
# spec/spec_helper.rb
require 'bundler/setup'
require 'json'
require 'rack/mock'
require 'rspec'
require 'tempfile'
require 'otto'

module OttoAppSpecHelpers
  def rack_env(path = '/', method: 'GET', headers: {}, params: {})
    env = Rack::MockRequest.env_for(path, method: method, params: params)
    headers.each do |name, value|
      rack_name = name.upcase.tr('-', '_')
      # Rack keeps Content-Type and Content-Length unprefixed; everything else
      # is HTTP_-prefixed. Without this, a JSON request never reaches Otto's
      # JSON parser.
      key = %w[CONTENT_TYPE CONTENT_LENGTH].include?(rack_name) ? rack_name : "HTTP_#{rack_name}"
      env[key] = value
    end
    env
  end

  def build_otto(route_lines, **options)
    file = Tempfile.new(['routes', '.txt'])
    file.write(route_lines.join("\n") + "\n")
    file.close
    (@route_files ||= []) << file

    Otto.new(file.path, options)
  end
end

RSpec.configure do |config|
  config.include OttoAppSpecHelpers

  config.after do
    Array(@route_files).each(&:unlink)
  end
end
```

Within Otto itself, use the existing helpers in
[`spec/support/test_helpers.rb`](../../spec/support/test_helpers.rb) instead of
copying this application-level helper.

## Test Logic classes as plain Ruby objects

Logic classes receive an authentication result, merged parameters, and a locale.
Test business rules without a Rack request when request parsing is not part of
the behavior under test:

```ruby
RSpec.describe Products::Show do
  let(:context) do
    Otto::Security::Authentication::StrategyResult.new(
      session: { 'user_id' => 7 },
      user: { id: 7, roles: ['customer'] },
      auth_method: 'session',
      metadata: {},
      strategy_name: 'session'
    )
  end

  it 'rejects a product owned by another user' do
    product = instance_double(Product, owner_id: 9)
    allow(Product).to receive(:find).with('42').and_return(product)

    logic = described_class.new(context, { id: '42' }, 'en')

    expect { logic.raise_concerns }
      .to raise_error(Otto::Security::AuthorizationError)
  end
end
```

Constructing a `StrategyResult` directly is appropriate in an isolated unit
test. Application request handling should use the result Otto places in
`env['otto.strategy_result']`.

Otto invokes `raise_concerns` before `process`. For `response=json`, the JSON
handler may call an optional `response_data` formatting hook after `process`.
Do not implement `response_data` by rerunning mutating business logic.

See [`spec/otto/route_handlers_spec.rb`](../../spec/otto/route_handlers_spec.rb)
for lifecycle, parameter, locale, and JSON-body coverage.

## Test route definitions against the current contract

`RouteDefinition` uses symbols for verbs and handler kinds. Multi-value accessors
return arrays:

```ruby
RSpec.describe Otto::RouteDefinition do
  it 'parses authentication, roles, and a Logic target' do
    route = described_class.new(
      'GET',
      '/admin',
      'Admin::Dashboard auth=session,api_key role=admin,editor response=json'
    )

    expect(route.verb).to eq(:GET)
    expect(route.kind).to eq(:logic)
    expect(route.klass_name).to eq('Admin::Dashboard')
    expect(route.method_name).to eq('Dashboard')
    expect(route.auth_requirement).to eq('session')
    expect(route.auth_requirements).to eq(%w[session api_key])
    expect(route.role_requirement).to eq('admin,editor')
    expect(route.role_requirements).to eq(%w[admin editor])
    expect(route.response_type).to eq('json')
  end
end
```

Handler kinds are `:class`, `:instance`, `:logic`, and `:lambda`. The complete
parser contract is covered by
[`spec/otto/route_definition_spec.rb`](../../spec/otto/route_definition_spec.rb).

## Test a strategy directly

A strategy unit test should cover successful credentials, missing credentials,
and rejected credentials. Explicit credentials that were examined and rejected
should normally produce a terminal failure so a later anonymous strategy cannot
accept the request.

```ruby
RSpec.describe Otto::Security::Authentication::Strategies::APIKeyStrategy do
  subject(:strategy) { described_class.new(api_keys: ['test-key']) }

  it 'authenticates the configured header value without exposing it' do
    result = strategy.authenticate(
      rack_env('/', headers: { 'X-API-Key' => 'test-key' }),
      'api_key'
    )

    expect(result).to be_authenticated
    expect(result.metadata[:api_key_fingerprint]).to be_a(String)
    expect(result.to_h.inspect).not_to include('test-key')
  end

  it 'rejects an invalid explicit key terminally' do
    result = strategy.authenticate(
      rack_env('/', headers: { 'X-API-Key' => 'wrong-key' }),
      'api_key'
    )

    expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
    expect(result.failure_reason).to eq('Invalid API key')
    expect(result).to be_terminal
  end
end
```

Query/form API keys are ignored unless the strategy is created with
`param_name:`. Prefer header authentication because URLs are commonly logged.
The complete static-list and resolver contract is covered by
[`spec/otto/security/authentication/strategies/api_key_strategy_spec.rb`](../../spec/otto/security/authentication/strategies/api_key_strategy_spec.rb).

For a custom strategy, subclass
`Otto::Security::Authentication::AuthStrategy` and test the result returned by
`authenticate(env, requirement)`. Use `failure(reason, terminal: true)` only
when an explicit credential was presented and rejected. See the
[authentication guide](authentication.md) for the chain semantics.

## Test a complete request through Otto

A full-stack test should exercise a real route file, handler factory,
authentication wrapper, response handler, and Rack response tuple. A registered
lambda keeps this fixture self-contained:

```ruby
RSpec.describe 'a protected endpoint' do
  let(:otto) do
    app = build_otto(
      ['GET /protected &protected auth=session response=json'],
      lambda_handlers: {
        protected: ->(_req, _res, _path_params) { { ok: true } },
      }
    )
    app.add_auth_strategy(
      'session',
      Otto::Security::Authentication::Strategies::SessionStrategy.new
    )
    app
  end

  it 'returns JSON for an authenticated session' do
    env = rack_env('/protected')
    env['rack.session'] = { 'user_id' => 7 }

    status, headers, body = otto.call(env)

    expect(status).to eq(200)
    expect(headers['Content-Type']).to eq('application/json')
    expect(JSON.parse(body.join)).to eq('ok' => true)
  end

  it 'returns a JSON 401 without a session' do
    status, headers, body = otto.call(
      rack_env('/protected', headers: { 'Accept' => 'application/json' })
    )

    expect(status).to eq(401)
    expect(headers['content-type']).to eq('application/json')
    expect(JSON.parse(body.join)['error']).to eq('Authentication Required')
  end
end
```

For API-key failures, the JSON response uses `"Authentication Required"` in
`error` and places the specific reason, such as `"Invalid API key"`, in
`message`.

Use a role-aware strategy when testing `role=`. The built-in `SessionStrategy`
exposes the user ID but does not copy roles from `rack.session`; `role=` checks
the successful strategy result, not the session independently. See
[`spec/otto/security/authentication/route_auth_wrapper/role_authorization_spec.rb`](../../spec/otto/security/authentication/route_auth_wrapper/role_authorization_spec.rb)
for supported user shapes.

## Test JSON request parsing through a handler

Do not manually merge JSON and query hashes when the behavior under test is
Otto's parser. Send an `application/json` body through a real Otto instance or
`LogicClassHandler`, then assert on the parameters received by the Logic object.

Current behavior to cover explicitly:

- a JSON object is merged into the Logic parameters;
- a valid non-object JSON value is ignored;
- malformed JSON is logged and the Logic class continues with other parameters;
- non-JSON bodies are not parsed by the Logic handler.

The maintained executable examples are in the “JSON request body parsing”
context of
[`spec/otto/route_handlers_spec.rb`](../../spec/otto/route_handlers_spec.rb).

## Test configuration freezing explicitly

`Otto#call` does not automatically freeze configuration while `RSpec` is
defined. Freeze the instance directly in tests that assert the production boot
boundary:

```ruby
RSpec.describe 'configuration freezing' do
  it 'rejects later strategy registration' do
    otto = build_otto(['GET / &health'], lambda_handlers: {
      health: ->(_req, res, _path_params) { res.body = 'ok' },
    })
    otto.freeze_configuration!

    expect(otto.frozen_configuration?).to be(true)
    expect {
      otto.add_auth_strategy('other', Object.new)
    }.to raise_error(FrozenError, /Cannot modify frozen configuration/)
  end
end
```

Use a fresh Otto instance after an explicit freeze. `Otto.unfreeze_for_testing`
only resets an internal flag; it cannot unfreeze nested Ruby objects. See the
[configuration-freezing guide](configuration_freezing.md) and
[`spec/otto/configuration_freezing_spec.rb`](../../spec/otto/configuration_freezing_spec.rb).

## Test CSRF at the correct layers

CSRF has two distinct components:

- `Otto::Security::Middleware::CSRFMiddleware` injects generated tokens into
  HTML responses containing a `<head>` element.
- `Otto::Security::CSRFEnforcementWrapper` validates unsafe requests after route
  matching, where it can honor `csrf=exempt`.

Enable CSRF on an `Otto::Security::Config` before testing either component.
Valid request tokens must come from `config.generate_csrf_token(session_id)` and
must use the matching session ID; an arbitrary value copied into the session and
header is not a valid token.

Use these maintained specs as executable examples:

- [`spec/security_csrf_spec.rb`](../../spec/security_csrf_spec.rb) — response injection.
- [`spec/otto/security/csrf_enforcement_wrapper_spec.rb`](../../spec/otto/security/csrf_enforcement_wrapper_spec.rb) — safe methods, unsafe methods, valid tokens, and `csrf=exempt`.
- [`spec/otto/security/csrf_validation_spec.rb`](../../spec/otto/security/csrf_validation_spec.rb) — token and session extraction.

## Test IP privacy with the application configuration

The middleware class is
`Otto::Security::Middleware::IPPrivacyMiddleware`. It receives a security
configuration object, not `masking_level:` or `skip_private_ips:` keywords:

```ruby
RSpec.describe Otto::Security::Middleware::IPPrivacyMiddleware do
  it 'masks a public IPv4 address' do
    inner = ->(_env) { [200, {}, ['ok']] }
    security_config = Otto::Security::Config.new
    middleware = described_class.new(inner, security_config)
    env = rack_env('/')
    env['REMOTE_ADDR'] = '203.0.113.45'

    middleware.call(env)

    expect(env['REMOTE_ADDR']).to eq('203.0.113.0')
  end
end
```

Set `security_config.ip_privacy_config.octet_precision = 2` to mask two IPv4
octets, or set `mask_private_ips = true` to include private and localhost
addresses. For application-facing tests, prefer a real Otto instance configured
through `configure_ip_privacy`.

See the [privacy guide](privacy.md) and the maintained privacy specs:

- [`spec/otto/ip_privacy_spec.rb`](../../spec/otto/ip_privacy_spec.rb)
- [`spec/otto/ip_precision_capability_spec.rb`](../../spec/otto/ip_precision_capability_spec.rb)

## Test expected errors through the public request path

Register expected business errors before the freeze boundary, trigger them from
a route, and assert the returned status and response format. This verifies route
content negotiation and centralized error handling together. Direct calls to
private methods such as `handle_error` are useful for Otto's own unit tests but
should not be the main application-level pattern.

The maintained coverage is in:

- [`spec/otto/error_handler_registration_spec.rb`](../../spec/otto/error_handler_registration_spec.rb)
- [`spec/otto/error_handling_spec.rb`](../../spec/otto/error_handling_spec.rb)

## Security-header expectations

Otto's default route responses include:

- `x-content-type-options: nosniff`
- `x-xss-protection: 1; mode=block`
- `referrer-policy: strict-origin-when-cross-origin`

`x-frame-options` is not a default header. Call
`otto.enable_frame_protection!` before the first request if a test should expect
`x-frame-options: SAMEORIGIN`.

Test security behavior at the narrowest useful level, but do not require every
unrelated unit test to repeat header and privacy assertions. Keep those checks in
focused middleware or request specs.

## Maintained examples by task

- Authentication responses and route roles:
  [`spec/otto/security/route_auth_wrapper_spec.rb`](../../spec/otto/security/route_auth_wrapper_spec.rb)
- Terminal API-key behavior:
  [`spec/otto/security/authentication/api_key_fail_closed_integration_spec.rb`](../../spec/otto/security/authentication/api_key_fail_closed_integration_spec.rb)
- Registered lambda routes and response types:
  [`spec/otto/lambda_routes_integration_spec.rb`](../../spec/otto/lambda_routes_integration_spec.rb)
- Response selection:
  [`spec/otto/response_integration_spec.rb`](../../spec/otto/response_integration_spec.rb)
- Static files after freezing:
  [`spec/otto/static_file_freezing_spec.rb`](../../spec/otto/static_file_freezing_spec.rb)
