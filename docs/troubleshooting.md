# Otto Troubleshooting Guide

Solutions to common issues and debugging tips.

## Routes and Routing

### Routes Not Matching

**Problem**: A URL that should match a route returns 404 Not Found.

**Common Causes**:

1. **HTTP Method Mismatch**
   ```
   routes file says: GET /users
   Request:         POST /users  ← Won't match!
   ```
   **Solution**: Ensure the HTTP method in your routes file matches the request.

2. **Path Doesn't Match Exactly**
   ```
   routes file says: GET /about
   URL:              GET /about/  ← Won't match! (trailing slash)
   ```
   **Solution**: Match the path exactly, or use a dynamic route with optional trailing slash.

3. **Dynamic Route Parameter Issue**
   ```
   routes file says: GET /users/:id/profile
   URL:              GET /users/alice  ← Won't match (missing /profile)
   ```
   **Solution**: Provide all path segments, or use a catch-all: `GET /users/:id/*`

4. **Routes File Not Being Loaded**
   ```ruby
   # Wrong: routes file not found
   Otto.new("./Routes")  # Should be ./routes (lowercase)
   ```
   **Solution**: Check the routes file path and filename.

5. **Order Matters for Dynamic Routes**
   ```
   routes file:
   GET  /users/:id
   GET  /users/special
   ```
   **Problem**: If dynamic route comes first, `/users/special` might be matched as `:id=special`.
   **Solution**: Put more specific routes before generic ones.

**Debugging**:
```ruby
# Enable debug logging
Otto.debug = true
otto = Otto.new(routes)

# Check if route matches in browser console
# Add a catch-all route to see what's not matching:
GET  /404-debug  App#debug_route

# In debug_route:
def debug_route
  @res.body = "Route: #{@req.path}, Method: #{@req.request_method}"
end
```

---

## Handler and Method Issues

### Method Not Found / NoMethodError

**Problem**: `undefined method 'show_user' for App:Class`

**Causes**:

1. **Method Doesn't Exist**
   ```ruby
   # routes file says:
   GET  /users/:id  App#show_user

   # But app.rb has:
   class App
     def show_users  # <- Wrong name (plural, not singular)
     end
   end
   ```
   **Solution**: Match the method name exactly (case-sensitive).

2. **Method Not Public**
   ```ruby
   class App
     private
     def show_user  # <- Private method not accessible
     end
   end
   ```
   **Solution**: Make sure methods are public or remove `private`/`protected`.

3. **Class Name Mismatch**
   ```
   routes file says: App#show_user
   But your class is:  class MyApp
   ```
   **Solution**: Ensure class name matches exactly.

4. **Missing `require` Statement**
   ```ruby
   # config.ru
   run Otto.new("./routes")  # Otto doesn't know where App is!

   # Should be:
   require './app'
   run Otto.new("./routes")
   ```
   **Solution**: Require all app files before creating Otto instance.

---

## Security and CSRF

### CSRF Token Validation Errors

**Problem**: Form submission returns 403 Forbidden with CSRF token error.

**Causes**:

1. **CSRF Protection Enabled but No Token in Form**
   ```ruby
   # config.ru
   app.enable_csrf_protection!

   # But form has no token:
   # <form method="post"><input type="text"></form>
   ```
   **Solution**: Include CSRF token in form:
   ```erb
   <form method="post">
     <input type="hidden" name="_csrf_token" value="<%= @req.csrf_token %>">
     <input type="text" name="message">
   </form>
   ```

2. **Token Mismatch**
   ```
   Token generated:    abc123def456
   Token submitted:    abc123def457  ← Different!
   ```
   **Causes**:
   - User modified the token
   - Session changed between GET and POST
   - Multiple forms on page with different tokens

   **Solution**: Use same session for GET (to generate token) and POST (to submit).

3. **CSRF Exemption Wrong**
   ```
   routes file says: POST  /api/data  App#api_data  csrf=exempt
   But code checks:
   def api_data
     if request.csrf_valid?  # Checking manually!
       # ...
     end
   end
   ```
   **Problem**: `csrf=exempt` skips validation, so manual check fails.
   **Solution**: Remove manual CSRF check or remove `csrf=exempt` flag.

**Debugging**:
```ruby
def create_feedback
  # Check if token was received
  puts "Token in params: #{@req.params[:_csrf_token].inspect}"
  puts "Token expected: #{@req.csrf_token.inspect}"

  @res.body = "Debug info logged to console"
end
```

---

## Authentication Issues

### 401 Unauthorized When Access Should Be Allowed

**Problem**: Route requires `auth=token` but legitimate token requests return 401.

**Causes**:

1. **Token Not Being Sent**
   ```
   Route:   GET  /admin  AdminController#dashboard  auth=token
   Request: GET  /admin  ← No token parameter!
   ```
   **Solution**: Send token: `GET /admin?token=my_token`

2. **Token Format Wrong**
   ```ruby
   # config.ru
   app.add_auth_strategy('token', TokenStrategy.new(
     tokens: { 'my-token-123' => { user_id: 'alice' } }
   ))

   # But you're sending: ?token=my_token (doesn't match 'my-token-123')
   ```
   **Solution**: Use the exact token string configured.

3. **Parameter Name Wrong**
   ```
   Strategy expects: ?token=xyz
   But form sends:   ?api_key=xyz  ← Wrong parameter name
   ```
   **Solution**: Check your strategy configuration for expected parameter name.

4. **Strategy Not Added**
   ```ruby
   # config.ru - forgot to add strategy!
   app = Otto.new("./routes")
   # Missing: app.add_auth_strategy('token', ...)

   run app
   ```
   **Solution**: Add the strategy before creating the app or before first request.

**Debugging**:
```ruby
# Add debug route
GET  /auth-debug  AdminController#auth_debug  auth=token

# In controller:
def auth_debug
  @res.body = "User context: #{@req.user_context.inspect}"
end

# Visit with token: /auth-debug?token=my_token
```

### Unauthenticated but Getting No Error

**Problem**: Route requires auth but handler is called anyway (no 401).

**Causes**:

1. **Route Definition Missing `auth=`**
   ```
   routes file says: GET  /admin  AdminController#admin
                     # <- Missing  auth=token
   ```
   **Solution**: Add auth requirement: `GET  /admin  AdminController#admin  auth=token`

2. **Strategy Registered with Wrong Name**
   ```ruby
   app.add_auth_strategy('bearer', MyStrategy.new)  # Registered as 'bearer'

   # But routes says:
   GET  /admin  AdminController#admin  auth=token  # Looking for 'token'
   ```
   **Solution**: Match the strategy name in routes with registered name.

---

## Parameters and Input

### Parameters Not Being Captured

**Problem**: `@req.params` is empty or missing values.

**Causes**:

1. **Dynamic Route Not Defined**
   ```
   routes file says: GET  /users  App#list
                     # <- No :id parameter!

   def list
     user_id = @req.params[:id]  # Will be nil
   end
   ```
   **Solution**: Define route with parameters:
   ```
   GET  /users/:id  App#show
   ```

2. **Query String Not Sent**
   ```
   Route: GET  /search  App#search

   URL:   /search  ← No ?query=xyz
   ```
   **Solution**: Send parameters in URL: `/search?query=ruby`

3. **Form Data Not POST Method**
   ```html
   <form method="get" action="/submit">  <!-- GET, not POST -->
     <input name="message">
   </form>
   ```
   **Problem**: GET sends data in URL query string, POST in body.
   **Solution**: Use `method="post"` for form data, or access via `@req.params[:message]` for GET.

4. **Content-Type Not Set for POST**
   ```bash
   curl -X POST http://localhost/submit \
     -d "message=hello"  # Missing Content-Type header
   ```
   **Solution**: Add header:
   ```bash
   curl -X POST http://localhost/submit \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "message=hello"
   ```

---

## Privacy and IP Masking

### Real IP Appearing in Logs

**Problem**: Logging shows real IP like `203.0.113.50` instead of masked `203.0.113.0`.

**Causes**:

1. **Privacy Middleware Not Running First**
   ```ruby
   # config.ru
   builder.use Rack::CommonLogger  # Runs BEFORE privacy!
   builder.use Otto
   ```
   **Problem**: CommonLogger logs before privacy middleware masks the IP.
   **Solution**: Add IPPrivacyMiddleware first:
   ```ruby
   builder.use Otto::Security::Middleware::IPPrivacyMiddleware
   builder.use Rack::CommonLogger
   builder.use Otto
   ```

2. **Privacy Disabled**
   ```ruby
   otto.disable_ip_privacy!
   ```
   **Problem**: Explicitly disabled privacy.
   **Solution**: Remove this line or enable again with `Otto.new(routes)` (enabled by default).

3. **Private/Localhost IP**
   ```
   Request from: 127.0.0.1 (localhost)
   Logged as:    127.0.0.1  ← Correct! (private IPs never masked)
   ```
   **Problem**: This is expected behavior for development.
   **Solution**: No action needed. Private IPs are intentionally not masked.

---

## Response and Content Type Issues

### Wrong Content-Type Returned

**Problem**: Endpoint returns JSON but browser treats it as HTML.

**Causes**:

1. **Response Type Not Set**
   ```
   routes file says: GET  /users  UsersController#list
                     # <- Missing response=json
   ```
   **Solution**: Specify response type:
   ```
   GET  /users  UsersController#list  response=json
   ```

2. **Content-Type Header Not Set in Handler**
   ```ruby
   def list
     @res.body = JSON.generate([{id: 1}])
     # Missing: @res.header['Content-Type'] = 'application/json'
   end
   ```
   **Solution**: Set header:
   ```ruby
   def list
     @res.header['Content-Type'] = 'application/json'
     @res.body = JSON.generate([{id: 1}])
   end
   ```

3. **Implicit Response Type Not Working**
   ```
   routes file says: GET  /users  UsersController#list  response=json

   Handler returns string:
   def list
     @res.body = "invalid json"  # Should be JSON
   end
   ```
   **Solution**: Return proper JSON:
   ```ruby
   def list
     @res.body = JSON.generate([])
   end
   ```

---

## Server and Configuration Issues

### Port Already in Use

**Problem**: `Address already in use - bind(2) (Errno::EADDRINUSE)`

**Solution**:

1. Find process using the port:
   ```bash
   lsof -i :9292
   ```

2. Kill it:
   ```bash
   kill -9 <PID>
   ```

3. Or use a different port:
   ```bash
   rackup config.ru -p 9293
   ```

### Configuration Frozen Error

**Problem**: `FrozenError: can't modify frozen Hash`

**Causes**: Trying to modify Otto configuration after first request.

```ruby
otto = Otto.new(routes)
otto.call(env)  # First request - configuration freezes

# Now this fails:
otto.add_auth_strategy('token', MyStrategy.new)  # FrozenError!
```

**Solution**: Add all configuration BEFORE first request:

```ruby
otto = Otto.new(routes)
otto.add_auth_strategy('token', MyStrategy.new)  # Before first request!
otto.enable_csrf_protection!

# Now it's safe to use
app = Rack::Builder.new do
  run otto
end
```

---

## Performance Issues

### Slow Request Handling

**Problem**: Routes are slow to match or handlers are slow to execute.

**Debugging**:

1. **Enable Timing Logs**
   ```ruby
   Otto.debug = true
   # Check logs for duration values
   ```

2. **Check Middleware Stack**
   ```ruby
   # Each middleware adds latency
   otto = Otto.new(routes)
   puts otto.middleware.inspect
   # Remove unnecessary middleware
   ```

3. **Use Logic Classes for Heavy Computation**
   ```ruby
   # Instead of inline logic in route handler
   GET  /expensive  ProcessData  # Logic class handles computation

   # Logic classes have access to full request context
   class ProcessData
     def process(req, res)
       # Heavy computation here
       res.body = result
     end
   end
   ```

---

## Testing Issues

### Routes Not Matching in Tests

**Problem**: Routes work in browser but fail in tests.

**Causes**:

1. **Routes File Path Wrong in Test**
   ```ruby
   # Test uses relative path that doesn't work
   otto = Otto.new("./routes")  # Current directory might be different in test

   # Should use absolute path or
   otto = Otto.new(File.expand_path("../routes", __FILE__))
   ```

2. **Test Environment Missing Setup**
   ```ruby
   # Forgot to require app.rb
   def setup
     @otto = Otto.new("routes")  # App class not loaded!
     # Should be:
     require './app'
     @otto = Otto.new("routes")
   end
   ```

---

## Getting More Help

1. **Check Example Applications**: Run the examples and compare with your code
   - [examples/basic/](../examples/basic/)
   - [examples/advanced_routes/](../examples/advanced_routes/)
   - [examples/authentication_strategies/](../examples/authentication_strategies/)

2. **Read Detailed Documentation**:
   - [docs/architecture.md](architecture.md) - How Otto works internally
   - [docs/best-practices.md](best-practices.md) - Production patterns
   - [CLAUDE.md](../CLAUDE.md) - Comprehensive reference

3. **Enable Debug Mode**:
   ```ruby
   Otto.debug = true
   ```
   Check logs for detailed execution information.

4. **Use REPL/Rails Console**:
   ```ruby
   pry
   > require 'rack'
   > require 'otto'
   > require './app'
   > env = Rack::MockRequest.env_for("/users/123")
   > otto = Otto.new("./routes")
   > status, headers, body = otto.call(env)
   > status  # => 200 if route matched
   ```

---

## Quick Reference Checklist

**Route Not Found?**
- [ ] HTTP method matches (GET/POST/etc)
- [ ] Path matches exactly
- [ ] Routes file is loaded
- [ ] Routes file path is correct
- [ ] More specific routes come before generic ones

**Handler Not Called?**
- [ ] Class name matches (case-sensitive)
- [ ] Method name matches (case-sensitive)
- [ ] Method is public
- [ ] app.rb is required in config.ru

**CSRF Token Error?**
- [ ] CSRF token included in form
- [ ] Token matches expected token
- [ ] Session/cookies are preserved between GET and POST

**Auth Not Working?**
- [ ] Route includes `auth=strategy_name`
- [ ] Strategy is registered with correct name
- [ ] Token/credentials are being sent
- [ ] Strategy is added before first request

**Privacy Concern?**
- [ ] IPPrivacyMiddleware is first in stack
- [ ] Check if IP is private/localhost (those are intentionally unmasked)
- [ ] Enable Otto.debug to see what's masked
