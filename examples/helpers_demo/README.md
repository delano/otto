# Otto Helpers Demo
# README.md

This example demonstrates Otto's built-in request and response helpers.

## Features Demonstrated

### Request Helpers
- **Client Information**: IP address detection, user agent, server info
- **Security Helpers**: Local detection, HTTPS detection, AJAX detection
- **Locale Detection**: Multi-source locale resolution with Otto configuration
- **Header Collection**: Proxy header collection and formatting
- **Path Helpers**: Application path building

### Response Helpers
- **Secure Cookies**: Proper cookie security with TTL and session cookies
- **CSP Headers**: Content Security Policy with nonce support
- **Security Headers**: Default and custom security headers
- **Cache Control**: No-cache headers for sensitive content

## Running the Demo

```bash
cd examples/helpers_demo
bundle exec rackup -p 9292
```

Then visit http://localhost:9292 to explore the demos.

## Configuration Highlights

The app is configured with:
- **Locale support** for English, Spanish, and French
- **CSRF protection** for form submissions
- **Request validation** for input sanitization
- **CSP with nonce** for inline script security
- **Frame protection** against clickjacking

## Key Files

- `config.ru` - Otto configuration with security and locale features
- `routes` - URL routing definitions
- `app.rb` - Demonstration handlers showing helper usage

This example shows how Otto's helpers make it easy to build secure, internationalized web applications.
