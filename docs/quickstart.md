# Otto Quick Start Guide

Get your first Otto application running in 10 minutes.

## What You'll Build

A simple web application with:
- A single homepage route
- A feedback form that collects user input
- Security features enabled by default

## Prerequisites

- Ruby 3.2 or higher
- Rack 3.1 or higher
- A text editor
- Terminal/command line

## Step 1: Create Your App Directory

```bash
mkdir my_otto_app
cd my_otto_app
```

## Step 2: Create Three Files

### File 1: `routes`

Define your routes in plain text:

```
GET   /            MyApp#index
POST  /feedback    MyApp#receive_feedback
```

### File 2: `app.rb`

Your Ruby application class:

```ruby
# lib/otto/app.rb

class MyApp
  def initialize(req, res)
    @req = req
    @res = res
  end

  def index
    @res.body = <<~HTML
      <h1>Welcome to Otto</h1>
      <form method="post" action="/feedback">
        <input type="text" name="message" placeholder="Enter feedback">
        <button type="submit">Submit</button>
      </form>
    HTML
  end

  def receive_feedback
    message = @req.params[:message]
    @res.status = 302
    @res['Location'] = '/'
    @res.body = "Feedback received: #{message}"
  end
end
```

### File 3: `config.ru`

Rack configuration:

```ruby
# lib/otto/config.ru

require 'bundler/setup'
require 'otto'
require './app'

run Otto.new("./routes")
```

## Step 3: Create a Gemfile (Optional but Recommended)

```bash
bundle init
```

Then edit the Gemfile and add:

```ruby
gem 'otto'
gem 'rack'
```

Then run:

```bash
bundle install
```

## Step 4: Run Your App

Using `rackup`:

```bash
rackup config.ru
```

You should see:

```
Puma starting in single threaded mode...
* Version 3.12.0 (ruby 3.2.0-p0), codename: Llama Litter Box
* Min threads: 0, max threads: 32
* Environment: development
* Listening on tcp://127.0.0.1:9292
```

Open your browser to `http://localhost:9292` and you'll see your app!

## Step 5: Add More Routes

Let's add a `/about` page. Edit `routes`:

```
GET   /            MyApp#index
GET   /about       MyApp#about
POST  /feedback    MyApp#receive_feedback
```

Add the method to `app.rb`:

```ruby
def about
  @res.body = '<h1>About Us</h1><p>We build cool stuff with Otto.</p>'
end
```

Refresh your browser or restart the server if needed.

## Step 6: Enable Security Features

Update `config.ru` to enable security:

```ruby
require 'bundler/setup'
require 'otto'
require './app'

app = Otto.new("./routes")
app.enable_csrf_protection!

run app
```

CSRF protection is now enabled! Your forms automatically get CSRF tokens.

## Step 7: Add Authentication (Optional)

Create authentication strategies:

```ruby
# app.rb additions

require 'otto'

class MyApp
  # ... existing methods ...

  def admin_only
    user = @req.user_context[:user_id]
    @res.body = "Welcome, #{user}!"
  end
end
```

Update `config.ru`:

```ruby
require 'bundler/setup'
require 'otto'
require './app'

app = Otto.new("./routes")

# Add authentication strategy
app.add_auth_strategy('token', Otto::Security::Authentication::Strategies::TokenStrategy.new(
  tokens: { 'secret_token' => { user_id: 'alice' } }
))

app.enable_csrf_protection!

run app
```

Update `routes` to protect a route:

```
GET   /            MyApp#index
GET   /about       MyApp#about
POST  /feedback    MyApp#receive_feedback
GET   /admin       MyApp#admin_only auth=token
```

Now `/admin` requires a token. Access it via:
```
http://localhost:9292/admin?token=secret_token
```

## Next Steps

1. **Explore Examples**: Check out the [examples/](../examples/) directory:
   - [Basic Example](../examples/basic/) - More detailed basic setup
   - [Authentication Strategies](../examples/authentication_strategies/) - Multiple auth methods
   - [Security Features](../examples/security_features/) - CSRF, input validation, file uploads
   - [Advanced Routes](../examples/advanced_routes/) - Logic classes, response types, namespaced routing

2. **Learn More**:
   - Read [CLAUDE.md](../CLAUDE.md) for architectural patterns and best practices
   - Check [docs/architecture.md](architecture.md) for how Otto works internally
   - Review [docs/best-practices.md](best-practices.md) for production patterns

3. **Common Tasks**:
   - [Handling Errors Gracefully](best-practices.md#error-handling)
   - [Structuring Larger Apps](architecture.md#multi-app-architectures)
   - [Adding Logging](../examples/logging_improvements.rb)
   - [Protecting Routes](../examples/authentication_strategies/)

## Troubleshooting

**Routes not matching?**
- Make sure the HTTP method (GET, POST, etc.) matches your request
- Check that the path matches exactly (spaces matter in the routes file)
- See [docs/troubleshooting.md](troubleshooting.md) for more help

**Method not found errors?**
- Ensure the class name matches (case-sensitive)
- Make sure the method is public in your class
- Check that the method exists in your app.rb file

**CSRF token errors?**
- If CSRF protection is enabled, all POST/PUT/DELETE requests need CSRF tokens
- The token is automatically provided in HTML forms via `req.csrf_token`
- See [Security Features Example](../examples/security_features/) for implementation details

## Key Concepts

| Concept | Explanation |
|---------|-------------|
| **Routes File** | Plain-text file mapping HTTP method + path to class methods |
| **App Class** | Ruby class with methods called by routes (one instance per request) |
| **Request/Response** | Otto provides `@req` (Rack::Request) and `@res` (Rack::Response) |
| **Privacy by Default** | Public IPs automatically masked, user agents anonymized, no external tracking |
| **Security Features** | Optional CSRF, input validation, security headers (enable with methods) |

## Resources

- **Official Docs**: [CLAUDE.md](../CLAUDE.md)
- **Architecture**: [docs/architecture.md](architecture.md)
- **Examples**: [examples/](../examples/)
- **Troubleshooting**: [docs/troubleshooting.md](troubleshooting.md)
- **Best Practices**: [docs/best-practices.md](best-practices.md)
- **Changelog**: [CHANGELOG.rst](../CHANGELOG.rst)

Happy building! 🚀
