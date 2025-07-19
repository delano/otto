# Otto - 1.2 (2025-01-18)

**Auto-define your rack-apps in plain-text with built-in security.**

## Overview

Apps built with Otto have three, basic parts: a rackup file, a ruby file, and a routes file. If you've built a [Rack app](https://github.com/rack/rack) before, then you've seen a rackup file before. The ruby file is your actual app and the routes file is what Otto uses to map URI paths to a Ruby class and method.

A barebones app directory looks something like this:

```bash
  $ cd myapp
  $ ls
  config.ru app.rb routes
```

See the examples/ directory for a working app.


### Routes

The routes file is just a plain-text file which defines the end points of your application. Each route has three parts:

 * HTTP verb (GET, POST, PUT, DELETE or HEAD)
 * URI path
 * Ruby class and method to call

Here is an example:

```ruby
  GET   /                         App#index
  POST  /                         App#receive_feedback
  GET   /redirect                 App#redirect
  GET   /robots.txt               App#robots_text
  GET   /product/:prodid          App#display_product

  # You can also define these handlers when no
  # route can be found or there's a server error. (optional)
  GET   /404                      App#not_found
  GET   /500                      App#server_error
```

### App

There is nothing special about the Ruby class. The only requirement is that the first two arguments to initialize be a Rack::Request object and a Rack::Response object. Otherwise, you can do anything you want. You're free to use any templating engine, any database mapper, etc. There is no magic.

```ruby
  class App
    attr_reader :req, :res

    # Otto creates an instance of this class for every request
    # and passess the Rack::Request and Rack::Response objects.
    def initialize req, res
      @req, @res = req, res
    end

    def index
      res.header['Content-Type'] = "text/html; charset=utf-8"
      lines = [
        '<img src="/img/otto.jpg" /><br/><br/>',
        'Send feedback:<br/>',
        '<form method="post"><input name="msg" /><input type="submit" /></form>',
        '<a href="/product/100">A product example</a>'
      ]
      res.body = lines.join($/)
    end

    def receive_feedback
      res.body = req.params.inspect
    end

    def redirect
      res.redirect '/robots.txt'
    end

    def robots_text
      res.header['Content-Type'] = "text/plain"
      rules = 'User-agent: *', 'Disallow: /private'
      res.body = rules.join($/)
    end

    def display_product
      res.header['Content-Type'] = "application/json; charset=utf-8"
      prodid = req.params[:prodid]
      res.body = '{"product":%s,"msg":"Hint: try another value"}' % [prodid]
    end

    def not_found
      res.status = 404
      res.body = "Item not found!"
    end

    def server_error
      res.status = 500
      res.body = "There was a server error!"
    end
  end
```


### Rackup

There is also nothing special about the rackup file. It just builds a Rack app using your routes file.

```ruby
  require 'otto'
  require 'app'

  app = Otto.new("./routes")

  map('/') {
    run app
  }
```

With optional security features:

```ruby
  require 'otto'
  require 'app'

  app = Otto.new("./routes", {
    csrf_protection: true,           # Enable CSRF protection
    request_validation: true,        # Enable input validation
    trusted_proxies: ['10.0.0.0/8'], # Configure trusted proxies
    security_headers: {              # Custom security headers
      'content-security-policy' => "default-src 'self'; script-src 'self' 'unsafe-inline'"
    }
  })

  map('/') {
    run app
  }
```

See the examples/ directory for a working app.


## Security Features

Otto includes built-in security features that can be optionally enabled:

### CSRF Protection

Protects against Cross-Site Request Forgery attacks:

```ruby
  # Enable CSRF protection
  app = Otto.new("./routes", csrf_protection: true)

  # Or enable after initialization
  app.enable_csrf_protection!
```

When enabled, Otto will:
- Generate CSRF tokens for safe requests (GET, HEAD, OPTIONS, TRACE)
- Validate CSRF tokens for unsafe requests (POST, PUT, DELETE, PATCH)
- Inject CSRF meta tags into HTML responses
- Provide helpers for forms and AJAX requests

### Request Validation

Validates and sanitizes incoming requests:

```ruby
  # Enable request validation
  app = Otto.new("./routes", request_validation: true)

  # Or enable after initialization
  app.enable_request_validation!
```

Provides protection against:
- XSS attacks through input sanitization
- SQL injection pattern detection
- Oversized requests and parameter flooding
- Dangerous content types
- Invalid characters in headers and parameters

### Trusted Proxies

Configure trusted proxy servers for accurate IP detection:

```ruby
  app = Otto.new("./routes", trusted_proxies: [
    '10.0.0.0/8',     # Private networks
    '172.16.0.0/12',
    '192.168.0.0/16',
    /^127\.0\.0\.1$/  # Regex patterns also supported
  ])

  # Or add after initialization
  app.add_trusted_proxy('10.0.0.0/8')
```

### Security Headers

Otto automatically adds security headers to responses:

- `x-frame-options`: Prevents clickjacking
- `x-content-type-options`: Prevents MIME sniffing
- `x-xss-protection`: Enables XSS filtering
- `referrer-policy`: Controls referrer information
- `content-security-policy`: Prevents XSS and injection attacks
- `strict-transport-security`: Enforces HTTPS

Customize headers:

```ruby
  app.set_security_headers({
    'content-security-policy' => "default-src 'self'; script-src 'self' 'unsafe-inline'",
    'strict-transport-security' => 'max-age=31536000; includeSubDomains; preload'
  })
```

### Security Helpers

When security features are enabled, your app classes get additional helpers:

```ruby
  class App
    def initialize(req, res)
      @req, @res = req, res
    end

    def form_page
      res.headers['content-type'] = 'text/html'
      # CSRF protection helper
      csrf_tag = csrf_form_tag if respond_to?(:csrf_form_tag)

      res.body = <<-HTML
        <form method="post">
          #{csrf_tag}
          <input name="message" />
          <input type="submit" />
        </form>
      HTML
    end

    def process_input
      # Input validation helper
      safe_message = validate_input(req.params['message'], max_length: 500)
      res.body = "Received: #{safe_message}"
    end
  end
```

### Configuration Options

Security features are disabled by default for backward compatibility:

```ruby
  config = {
    csrf_protection: false,           # Enable CSRF protection
    request_validation: false,        # Enable input validation
    max_request_size: 10 * 1024 * 1024, # 10MB request size limit
    max_param_depth: 32,             # Maximum parameter nesting
    max_param_keys: 64,              # Maximum parameters per request
    trusted_proxies: [],             # Trusted proxy IP addresses
    security_headers: {}             # Custom security headers
  }

  app = Otto.new("./routes", config)
```


## Requirements

Otto requires Ruby 3.4+ and Rack 3.1+.


## Security Best Practices

### Production Deployment

When deploying Otto applications to production, enable security features:

```ruby
  app = Otto.new("./routes", {
    csrf_protection: true,
    request_validation: true,
    trusted_proxies: ['your.load.balancer.ip'],
    security_headers: {
      'strict-transport-security' => 'max-age=63072000; includeSubDomains; preload'
    }
  })
```

### Class Name Security

Otto validates route class names to prevent code injection:

- Class names must start with a capital letter
- Only alphanumeric characters and `::` for namespaces are allowed
- System classes like `Kernel`, `Object`, `File` are forbidden
- Relative references starting with `::` are blocked

### Input Validation

When `request_validation` is enabled, Otto automatically:

- Removes null bytes and control characters
- Detects XSS and SQL injection patterns
- Enforces request size limits
- Validates parameter depth and count
- Sanitizes file uploads

### CSRF Protection

Enable CSRF protection for forms and AJAX requests:

```ruby
  # In your app class
  def show_form
    csrf_tag = csrf_form_tag if respond_to?(:csrf_form_tag)
    res.body = "<form method='post'>#{csrf_tag}<input name='data'></form>"
  end
```

### Trusted Proxies

Configure trusted proxies to prevent IP spoofing:

```ruby
  app.add_trusted_proxy('10.0.0.0/8')       # Private networks
  app.add_trusted_proxy('172.16.0.0/12')    # Docker networks
  app.add_trusted_proxy(/^127\.0\.0\.1$/)   # Localhost (regex)
```

### Migrating Existing Apps

Otto's security features are disabled by default for backward compatibility:

1. **Test thoroughly** before enabling security features in production
2. **Start with validation** - enable `request_validation: true` first
3. **Add CSRF gradually** - enable for new forms, then existing ones
4. **Configure headers** that don't break your application's functionality
5. **Monitor logs** for security validation errors

### Security Headers Reference

Otto sets these security headers by default:

- `x-frame-options: DENY` - Prevents clickjacking
- `x-content-type-options: nosniff` - Prevents MIME sniffing
- `x-xss-protection: 1; mode=block` - Enables XSS filtering
- `referrer-policy: strict-origin-when-cross-origin` - Controls referrer
- `content-security-policy: default-src 'self'` - Prevents XSS/injection
- `strict-transport-security: max-age=31536000; includeSubDomains` - Forces HTTPS


## Installation

Get it in one of the following ways:

```bash
  $ gem install otto

  [ Add it to yer Gemfile]
  $ bundle install

  $ git clone git://github.com/delano/otto.git
```


You can also download via [tarball](https://github.com/delano/otto/tarball/latest) or [zip](https://github.com/delano/otto/zipball/latest).


## More Information

* [Homepage](https://github.com/delano/otto)


## In the wild

Services that use Otto:

* [Onetime Secret](https://onetimesecret.com/) -- A safe way to share sensitive data.



## License

See LICENSE.txt
