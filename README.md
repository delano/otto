# Otto - A Ruby Gem

**Define your rack-apps in plain-text with built-in security.**

> **v2.0.0-pre6 Available**: This pre-release includes major improvements to middleware management, logging, and request callback handling. See [changelog](CHANGELOG.rst) for details and upgrade notes.

![Otto mascot](public/img/otto.jpg "Otto - All Rack, no Pinion")

Otto apps have three files: a rackup file, a Ruby class, and a routes file. The routes file is just plain text that maps URLs to Ruby methods.

```bash
$ cd myapp && ls
config.ru app.rb routes
```

## Why Otto?

- **Security by Default**: Automatic IP masking for public addresses, user agent anonymization, CSRF protection, and input validation
- **Privacy First**: Masks public IPs, strips user agent versions, provides country-level geo-location only—no external APIs needed
- **Simple Routing**: Define routes in plain-text files with zero configuration overhead
- **Built-in Authentication**: Multiple strategies including API keys, tokens, role-based access, and custom implementations
- **Developer Friendly**: Works with any Rack server, minimal dependencies, easy testing and debugging

## Routes File
```
# routes

GET   /                         App#index
POST  /feedback                 App#receive_feedback
GET   /product/:id              App#show_product
GET   /robots.txt               App#robots_text
GET   /404                      App#not_found
```

## Ruby Class
```ruby
# app.rb

class App
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
    res.header['Content-Type'] = "text/plain"
    rules = 'User-agent: *', 'Disallow: /private/keep/out'
    res.body = rules.join($/)
  end
end
```

## Rackup File
```ruby
# config.ru

require 'otto'
require 'app'

run Otto.new("./routes")
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
   stack, which intercepts `POST`s to the report path, parses both the legacy
   `application/csp-report` and the Reporting API `application/reports+json`
   formats, enforces a 64 KiB body cap, and always answers `204 No Content` —
   without touching your routes.

Because the middleware is pinned outermost, it short-circuits ahead of the CSRF
middleware, so browsers can POST reports without a CSRF token — regardless of the
order you enable security features in. A throwing callback can never break the
receiver; it still answers `204`.

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

Private and localhost IPs are exempted by default for development convenience, but this behavior can be customized via `configure_ip_privacy()` method. Geolocation uses CDN headers (Cloudflare, AWS, etc.) with fallback to IP ranges—no external services required. See [CLAUDE.md](CLAUDE.md) for detailed configuration options.

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

## Examples

Otto includes comprehensive examples demonstrating different features:

- **[Basic Example](examples/basic/)** - Get your first Otto app running in minutes
- **[Advanced Routes](examples/advanced_routes/)** - Response types, CSRF exemption, logic classes, and namespaced routing
- **[Authentication Strategies](examples/authentication_strategies/)** - Token, API key, and role-based authentication
- **[Security Features](examples/security_features/)** - CSRF protection, input validation, file uploads, and security headers
- **[MCP Demo](examples/mcp_demo/)** - JSON-RPC 2.0 endpoints for CLI automation and integrations

### Standalone Tutorials

- **[Error Handler Registration](examples/error_handler_registration.rb)** - Prevent 500 errors for expected business exceptions
- **[Logging Improvements](examples/logging_improvements.rb)** - Structured logging with automatic timing
- **[Geo-location Extension](examples/simple_geo_resolver.rb)** - Extending geo-location with custom resolvers

See the [examples/](examples/) directory for more.

## Requirements

- Ruby 3.2+
- Rack 3.1+

## Installation

```bash
gem install otto
```

## Documentation

- **[CLAUDE.md](CLAUDE.md)** - Comprehensive developer guidance covering authentication architecture, configuration freezing, IP privacy, structured logging, and multi-app patterns
- **[docs/](docs/)** - Technical guides and migration guides
- **[CHANGELOG.rst](CHANGELOG.rst)** - Version history, breaking changes, and upgrade notes

## AI Development Assistance

Version 1.2.0's security features were developed with AI assistance:

* **Zed Agent (Claude Sonnet 4)** - Security implementation and testing
* **Claude Desktop** - Rack 3+ compatibility and debugging
* **GitHub Copilot** - Code completion

The maintainer remains responsible for all security decisions and implementation. We believe in transparency about development tools, especially for security-focused software.

## License

See LICENSE.txt
