# Otto - A Ruby Gem

**Define Rack apps in plain text, with privacy by default and opt-in security features.**

![Otto mascot](public/img/otto.jpg "Otto - All Rack, no Pinion")

Otto apps have three files: a rackup file, a Ruby class, and a routes file. The routes file is plain text that maps URLs to Ruby methods.

## Quick start

Requirements: Ruby `>= 3.2, < 4.1` and Rack `>= 3.1, < 4.0`.

Install Otto and the Rack server CLI, then create the three files shown below:

```sh
gem install otto rackup
mkdir myapp && cd myapp
```

After creating `routes`, `app.rb`, and `config.ru`, start the app and verify the response:

```sh
rackup config.ru
# In another terminal:
curl -i http://127.0.0.1:9292/
# HTTP/1.1 200 OK
# ...
# <h1>Hello Otto</h1>
```

## Why Otto?

- **Privacy by Default**: Masks public IP addresses and anonymizes user agents; country-level geo-location needs no external API
- **Opt-in Security Features**: CSRF protection, input validation, security headers, and trusted-proxy configuration
- **Simple Routing**: Define routes in plain-text files with zero configuration overhead
- **Built-in Authentication**: Multiple strategies including API keys, tokens, role-based access, and custom implementations
- **Developer Friendly**: Works with any Rack server, minimal dependencies, easy testing and debugging

## Routes File
```
# routes

GET   /                         App#index
GET   /product/:id              App#show_product
GET   /robots.txt               App#robots_text
```

## Ruby Class
```ruby
# app.rb

class App
  attr_reader :req, :res

  def initialize(req, res)
    @req, @res = req, res
  end

  def index
    res.body = '<h1>Hello Otto</h1>'
  end

  def show_product
    product_id = req.params[:id]
    res.body = "Product: #{product_id}"
  end

  def robots_text
    res.headers['content-type'] = 'text/plain'
    rules = 'User-agent: *', 'Disallow: /private/keep/out'
    res.body = rules.join($/)
  end
end
```

## Rackup File
```ruby
# config.ru

require 'otto'
require_relative 'app'

run Otto.new('routes')
```


## Security Features

Otto includes optional security features for production apps:

```ruby
# Enable security features
app = Otto.new("./routes", {
  csrf_protection: true,      # CSRF tokens and validation
  request_validation: true,   # Input sanitization and limits
  trusted_proxies: ['10.0.0.0/8']
})
```

Security features include CSRF protection, input validation, security headers, and trusted proxy configuration.

### Content Security Policy (nonce-based emission)

Otto owns the nonce lifecycle so the header and your views can never drift. A
request-scoped nonce is minted lazily on first access and memoized in the env;
your views read it to stamp `<script>`/`<link>` tags, and the framework reads
the *same* value to emit the `script-src 'nonce-…'` header.

```ruby
app = Otto.new("./routes")
app.enable_csp_with_nonce!    # turn on nonce-based CSP
app.enable_csp_emission!      # mount the backstop that writes the header

# In a view/handler:
def show(req, res)
  res['content-type'] = 'text/html; charset=utf-8'
  res.write(%(<script nonce="#{req.csp_nonce}">/* inline */</script>))
end
```

`enable_csp_emission!` mounts `Otto::Security::CSP::EmitMiddleware`, a passive
**backstop**:

- **Emit-if-consumed** (default): it emits a policy only for a response whose
  request actually consumed a nonce (a view called `req.csp_nonce`). A nonce-only
  `script-src` on an HTML page that never stamped the nonce would block every
  script, so "CSP responses whose request consumed a nonce" is the only safe
  blanket default. Pass `eager: true` to mint-and-emit for every eligible HTML
  response (see the caveat in the middleware docs).
- **Never clobbers**: it defers to any CSP a route already set.
- **HTML only**, and inert unless `enable_csp_with_nonce!` is on.
- `development_mode:` accepts a per-request callable, e.g.
  `->(env) { ENV['RACK_ENV'] == 'development' }`, to switch directive sets.

To set a policy explicitly from a handler instead, use the one emission helper —
it routes through the same apply core:

```ruby
res['content-type'] = 'text/html; charset=utf-8'
result = res.apply_csp(req.csp_nonce)          # mode: :override by default
result.applied?        # => true
result.skip_reason     # => nil (or :disabled / :blank_nonce / :non_html / :existing_csp)
```

Apps with an existing nonce env-key convention can point the accessor at it with
`app.security_config.csp_nonce_key = 'onetime.nonce'` — the views and the header
still share one value. Boot-time policy shaping goes through
`security_config.csp_directive_overrides = { 'worker-src' => "'self' data: blob:" }`,
which replaces (or with `nil`, removes) a directive's sources wholesale.

#### Request-scoped directive extras

Some directive values only exist at request time — the canonical case is a
multi-tenant app that must allow the resolved tenant's SSO IdP origin in
`form-action`. The channel is **boot-time opt-in** (the env key is a write
surface any middleware in the Rack stack can reach, so it does not exist until
boot code says so):

```ruby
app.security_config.enable_csp_request_extras!  # default: off
```

With the channel enabled, a handler (or middleware) writes a hash of directive
name => additional source tokens to the env before the response is finalized:

```ruby
def signin(req, res)
  idp_origin = resolve_tenant(req).idp_origin  # e.g. "https://login.example-idp.com"
  req.env['otto.csp.extra_directives'] = { 'form-action' => [idp_origin] }
  # ... render as usual; the emitted CSP now carries the origin
end
```

Without the opt-in, the env key is ignored entirely — no sanitization, no
logs. The `Writer::Result` returned by the emission surfaces reports what
actually happened: `result.extra_directives` carries only the extras that
landed in the policy; rejected or dropped entries are excluded and logged with
request context instead.

The extras channel is **additive-only** and deliberately narrow:

- Tokens are appended to directives already present in the built policy,
  deduplicated. A directive that is *absent* (not in the base set, or removed
  by a boot override) is dropped — creating one at request time would tighten
  the policy (`form-action` does not fall back to `default-src`), and
  re-adding one would resurrect a deliberate removal.
- Directives that take **no value** (`upgrade-insecure-requests`,
  `block-all-mixed-content`) are refused during sanitization: a source appended
  there would emit `upgrade-insecure-requests https://…`, which browsers treat
  as malformed and discard — an extras key would silently switch the directive
  *off*. The policy assembler independently leaves such directives
  byte-identical for direct callers that bypass the sanitizer.
- Only **origins** are accepted: `scheme://host[:port]` with an http(s) scheme
  — no keywords (`'self'`, `'unsafe-inline'`), no scheme sources (`data:`,
  `https:`), no wildcards, no paths, nothing that could smuggle a separator.
- `script-src` (and `-elem`/`-attr`) and `default-src` are refused outright.
  For the script family that is defence-in-depth policy, not nonce protection
  (extras append, so the nonce would survive); `default-src` is refused
  because widening it widens every unlisted directive at once.
- Everything that fails validation is **dropped and logged** (`warn`, with the
  directive, token, and reason) — a hostile value never raises, and the
  response ships with the rest of the policy intact.

Otto validates defensively, but it is not the policy authority: the app
decides *which* origins to admit (resolve them from trusted per-request data,
never echo attacker-controlled input). Extras live only in the request env —
nothing is memoized on the (frozen-in-production) security config, so
concurrent requests can never bleed into each other. The constant
`Otto::EnvKeys::CSP::EXTRA_DIRECTIVES` (via `require 'otto/env_keys'`) names
the key for downstream apps.

> [!NOTE]
> `res.send_csp_headers(content_type, nonce)` is **deprecated** in favour of
> `res.apply_csp` / `enable_csp_emission!`. It remains as a thin shim over the
> same apply core (so its old quirks — a broken `'nonce-'` on a blank nonce, a
> CSP on non-HTML responses, a `warn` to stderr — are now fixed) and logs a
> one-time deprecation notice.

### CSP Violation Reporting

Otto can both emit Content-Security-Policy headers and receive the violation
reports browsers post back. Point a policy at a report path and register a
callback — Otto handles the HTTP ceremony (parsing both wire formats, the size
cap, the CSRF bypass) and hands your callback a normalized report:

```ruby
app = Otto.new("./routes")
app.enable_csp_with_nonce!            # emit a nonce-based CSP (see send_csp_headers)

app.enable_csp_reporting!("/_/csp-report") do |report|
  Otto.logger.warn("CSP violation: #{report.violated_directive} " \
                   "blocked #{report.blocked_uri}")
  # report also exposes: document_uri, source_file, line_number,
  # column_number, disposition, effective_directive, ... and report.to_h
end
```

`enable_csp_reporting!` does three things:

1. Appends a `report-uri /_/csp-report` directive to every emitted CSP policy —
   both the static `enable_csp!` policy and the per-request nonce policy — so
   browsers know where to send violations.
2. Registers your callback, invoked once per violation with an
   `Otto::Security::CSP::Report`.
3. Injects `Otto::Security::CSP::ReportMiddleware`, pinned **outermost** in the
   stack (only IP masking runs ahead of it), which intercepts `POST`s to the
   report path, parses both the legacy
   `application/csp-report` and the Reporting API `application/reports+json`
   formats, enforces a 64 KiB body cap, and always answers `204 No Content` —
   without touching your routes.

Because the middleware is pinned outermost, it short-circuits ahead of the CSRF
middleware, so browsers can POST reports without a CSRF token — regardless of the
order you enable security features in. A throwing callback can never break the
receiver; it still answers `204`.

Modern browsers (Chrome) have deprecated `report-uri` in favour of the Reporting
API. Pass `endpoint_url:` — an **absolute** URL whose path is the report path —
to also emit a `report-to` directive and a `Reporting-Endpoints` response header,
so those browsers deliver `application/reports+json` to the same receiver:

```ruby
app.enable_csp_reporting!("/_/csp-report",
                          endpoint_url: "https://example.com/_/csp-report") do |report|
  Otto.logger.warn("CSP violation: #{report.violated_directive}")
end
```

The legacy `report-uri` is always kept alongside `report-to`, so older browsers
(Firefox, Safari) keep working. When `endpoint_url:` is omitted, output is
byte-identical to `report-uri`-only.

> [!IMPORTANT]
> Report URL fields (`document_uri`, `blocked_uri`, `referrer`, `source_file`)
> reflect the page the browser was on and may carry sensitive path/query data in
> some applications. Otto does **not** redact them — normalize/redact in your
> callback per your own privacy policy before logging or forwarding.

## Error Handling

Otto provides base error classes that automatically return correct HTTP status codes:

```ruby
# Use built-in error classes directly
raise Otto::NotFoundError, "Product not found"           # Returns 404
raise Otto::BadRequestError, "Invalid parameter"         # Returns 400
raise Otto::UnauthorizedError, "Login required"          # Returns 401
raise Otto::ForbiddenError, "Access denied"              # Returns 403

# Or subclass them for your application
class MyApp::ResourceNotFound < Otto::NotFoundError; end

# Optionally customize status or logging (overrides auto-registration)
app.register_error_handler(MyApp::ResourceNotFound, status: 410, log_level: :warn)
```

All framework errors are auto-registered during initialization. No manual registration required unless you want custom behavior.

## Privacy by Default

Otto automatically masks public IP addresses and anonymizes user agents to comply with GDPR, CCPA, and other privacy regulations:

```ruby
# Public IPs are automatically masked (203.0.113.9 → 203.0.113.0)
# Private IPs are NOT masked by default (127.0.0.1, 192.168.x.x, 10.x.x.x)
app = Otto.new("./routes")

# User agents: versions stripped for privacy
# Geo-location: country-level only, no external APIs or databases
# IP hashing: daily-rotating hashes enable analytics without tracking
```

Private and localhost IPs are exempted by default for development convenience, but this behavior can be customized via `configure_ip_privacy()` method. Geolocation checks CDN headers (Cloudflare, AWS, Vercel, etc.) first, then an optional local country database—no external services required. You can name a trusted header to check first, plug in a MaxMind-format `.mmdb` file for an offline fallback, or bring your own reader:

```ruby
otto.configure_ip_privacy(
  geo_header: 'X-Client-Country',        # trusted app header, checked first
  geo_db_path: 'data/country.mmdb'       # offline fallback (needs the maxmind-db gem)
)
```

Geo headers are only trusted for requests that arrive via a configured trusted proxy (they are client-spoofable otherwise), the database is looked up on the already-masked IP, and `configure_ip_privacy(geo: false)` disables geo entirely. See [AGENTS.md](AGENTS.md) for detailed configuration options.

## Internationalization Support

Otto provides built-in locale detection and management:

```ruby
# Global configuration (affects all Otto instances)
Otto.configure do |opts|
  opts.available_locales = { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' }
  opts.default_locale = 'en'
end

# Or configure during initialization
app = Otto.new("./routes", {
  available_locales: { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' },
  default_locale: 'en'
})

# Or configure at runtime
app.configure(
  available_locales: { 'en' => 'English', 'es' => 'Spanish' },
  default_locale: 'en'
)

# Legacy support (still works)
app = Otto.new("./routes", {
  locale_config: {
    available_locales: { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' },
    default_locale: 'en'
  }
})
```

In your application, use the locale helper:

```ruby
class App
  def initialize(req, res)
    @req, @res = req, res
  end

  def show_product
    # Automatically detects locale from:
    # 1. URL parameter: ?locale=es
    # 2. User preference (if provided)
    # 3. Accept-Language header
    # 4. Default locale
    locale = req.check_locale!

    # Use locale for localized content
    res.body = localized_content(locale)
  end
end
```

The locale helper checks multiple sources in order of precedence and validates against your configured locales.

## Network Service Integrations

Otto ships small, opt-in integrations for endpoints that an external network
component (a reverse proxy, a TLS layer) calls over a fixed HTTP contract. Each is
a self-contained, feature-named module — loaded but inert until you enable it, like
`Otto::MCP`. The app supplies a small decision; Otto owns the routing, the security
guard, and the fail-safe behavior.

The first integration, `Otto::CaddyTLS`, answers **Caddy's on-demand TLS** question — "may I obtain a
certificate for this domain?":

```ruby
otto = Otto.new('routes.txt')

otto.enable_caddy_tls! do |domain|
  # The only app-specific part. Truthy => 200 (allow), falsy => 403 (deny).
  # Any exception here is caught and denies (fail-closed).
  MyApp::CustomDomain.verified?(domain)
end
```

This serves `GET /_caddy/tls-permission?domain=<host>` and covers both Caddy's
deprecated `ask` directive and its replacement `permission http` module (identical
HTTP contract, so migration is config-only):

```caddyfile
on_demand_tls {
  permission http { endpoint http://127.0.0.1:PORT/_caddy/tls-permission }
}
```

Secure by default: the endpoint is restricted to the loopback interface (the guard
authenticates the raw TCP peer, so a spoofed `X-Forwarded-For` cannot help), and
every layer fails closed. See the [Caddy TLS guide](docs/guides/caddy-tls.md)
for deployment guidance and [ADR-003](docs/adr/adr-003-caddy-tls-route-based-integration.md)
for rationale.

## Examples

Otto includes comprehensive examples demonstrating different features:

- **[Basic Example](examples/basic/)** - Get your first Otto app running in minutes
- **[Advanced Routes](examples/advanced_routes/)** - Response types, CSRF exemption, logic classes, and namespaced routing
- **[Authentication Strategies](examples/authentication_strategies/)** - Token, API key, and role-based authentication
- **[Security Features](examples/security_features/)** - CSRF protection, input validation, file uploads, and security headers
- **[MCP Demo](examples/mcp_demo/)** - JSON-RPC 2.0 endpoints for CLI automation and integrations
- **[Caddy on-demand TLS](examples/caddy_tls_demo/)** - Reverse-proxy permission endpoint via `Otto::CaddyTLS`

### Standalone Tutorials

- **[Error Handler Registration](examples/error_handler_registration.rb)** - Prevent 500 errors for expected business exceptions
- **[Logging Improvements](examples/logging_improvements.rb)** - Structured logging with automatic timing
- **[Geo-location Extension](examples/simple_geo_resolver.rb)** - Extending geo-location with custom resolvers

See the [examples/](examples/) directory for more.


## Documentation

- **[Documentation map](docs/README.md)** - Capabilities, current guides, and the documentation structure Otto is growing toward
- **[AGENTS.md](AGENTS.md)** - Contributor and agent guidance for Otto conventions; it is not application documentation
- **[CHANGELOG.rst](CHANGELOG.rst)** - Version history, breaking changes, and upgrade notes

## AI Development Assistance

Version 1.2.0's security features were developed with AI assistance:

* **Zed Agent (Claude Sonnet 4)** - Security implementation and testing
* **Claude Desktop** - Rack 3+ compatibility and debugging
* **GitHub Copilot** - Code completion

The maintainer remains responsible for all security decisions and implementation. We believe in transparency about development tools, especially for security-focused software.

## License

See LICENSE.txt
