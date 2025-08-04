# Otto - A Ruby Gem

**Define your rack-apps in plain-text with built-in security.**

![Otto mascot](public/img/otto.jpg "Otto - All Rack, no Pinion")

Otto apps have three files: a rackup file, a Ruby class, and a routes file. The routes file is just plain text that maps URLs to Ruby methods.

```bash
$ cd myapp && ls
config.ru app.rb routes
```

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

## Requirements

- Ruby 3.2+
- Rack 3.1+

## Installation

```bash
gem install otto
```

## AI Development Assistance

Version 1.2.0's security features were developed with AI assistance:

* **Zed Agent (Claude Sonnet 4)** - Security implementation and testing
* **Claude Desktop** - Rack 3+ compatibility and debugging
* **GitHub Copilot** - Code completion

The maintainer remains responsible for all security decisions and implementation. We believe in transparency about development tools, especially for security-focused software.

## License

See LICENSE.txt
