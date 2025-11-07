# Otto - Authentication Strategies Example

This example demonstrates Otto's flexible authentication system with multiple strategies, token validation, and role-based access control.

## What You'll Learn

- How to configure multiple authentication strategies
- Token-based authentication with session validation
- API key authentication for programmatic access
- Role and permission-based access control
- How to protect routes with authentication requirements
- Handling authentication failures and redirects

## Structure

- `config.ru`: Rack configuration that initializes Otto and loads auth strategies
- `routes`: Application routes with authentication requirements
- `app/auth.rb`: Authentication strategy definitions and token setup
- `app/controllers/`: Handler classes for protected and public routes

## Authentication Strategies in This Example

### Token-Based Auth
Validates user tokens for web applications:
```
GET  /profile  HomeController#profile  auth=token
```
Requires: `?token=demo_token`

### Admin Role Auth
Validates admin-level access:
```
GET  /admin    AdminController#dashboard  auth=admin
```
Requires: `?token=admin_token`

### Permission-Based Auth
Validates specific permissions:
```
POST /edit     ArticleController#update  auth=can_write
```
Requires: `?token=demo_token` (with write permission)

### API Key Auth
Validates API keys for programmatic access:
```
GET  /api/data  ApiController#show  auth=api_key
```
Requires: `?api_key=demo_api_key_123`

## How to Run

### Using rackup (recommended)

```sh
cd examples/authentication_strategies
rackup config.ru
```

### Using alternative servers

```sh
thin -R config.ru -p 9292 start
puma config.ru -p 9292
```

Open your browser and navigate to `http://localhost:9292`.

## Testing Authentication

### Web Browser (Token-based)

Click these links or visit them directly:

- **Public page**: [http://localhost:9292/](http://localhost:9292/)
- **Authenticated user**: [http://localhost:9292/profile?token=demo_token](http://localhost:9292/profile?token=demo_token)
- **Admin user**: [http://localhost:9292/admin?token=admin_token](http://localhost:9292/admin?token=admin_token)
- **User with write permission**: [http://localhost:9292/edit?token=demo_token](http://localhost:9292/edit?token=demo_token)

### curl Commands (API Key)

```sh
# Without API key (fails)
curl http://localhost:9292/api/data

# With API key (succeeds)
curl "http://localhost:9292/api/data?api_key=demo_api_key_123"
```

### Testing Invalid Credentials

Try accessing protected routes without valid credentials:

```sh
# No token - redirects to login or returns 401
curl http://localhost:9292/profile

# Invalid token - returns 401
curl "http://localhost:9292/profile?token=invalid"

# Wrong token type - returns 401
curl "http://localhost:9292/admin?api_key=demo_api_key_123"
```

## Expected Output

### Successful Authentication
```
HTTP/1.1 200 OK
Content-Type: text/html

<h1>Welcome, alice!</h1>
<p>This is your profile.</p>
```

### Failed Authentication
```
HTTP/1.1 401 Unauthorized
Content-Type: text/plain

Unauthorized
```

### Redirect to Login
```
HTTP/1.1 302 Found
Location: http://localhost:9292/?login=required
```

## File Structure Details

### Routes File
- Public routes (no `auth=` requirement)
- Protected routes with different auth strategies
- Admin-only routes
- API routes with API key authentication

### Auth Strategies (`app/auth.rb`)
- Token validation logic with demo tokens
- Admin role checking
- Permission validation (read, write, admin)
- API key validation for programmatic access

### Controllers (`app/controllers/`)
- Welcome controller for public pages
- Profile controller for authenticated users
- Admin controller for admin-only pages
- Article controller for permission-based access
- API controller for programmatic access

## Key Concepts

### Strategy Registration
Strategies are registered in `config.ru` before the first request:

```ruby
app.add_auth_strategy('token', TokenStrategy.new)
app.add_auth_strategy('admin', AdminStrategy.new)
app.add_auth_strategy('api_key', APIKeyStrategy.new)
```

### Route Protection
Routes specify their auth requirement in the routes file:

```
GET  /protected  Controller#method  auth=token
POST /admin      Controller#admin   auth=admin
```

### User Context
After successful authentication, `req.user_context` contains user info:

```ruby
def profile
  user_id = @req.user_context[:user_id]
  @res.body = "Welcome, #{user_id}!"
end
```

## Demo Credentials

### Tokens
- `demo_token` - Regular user (Alice)
  - Permissions: read, write
  - Roles: user
- `admin_token` - Administrator
  - Permissions: read, write, admin
  - Roles: admin, user

### API Keys
- `demo_api_key_123` - Demo API access
- Additional keys can be added to `app/auth.rb`

## Customizing Authentication

To add your own authentication:

1. **Create a strategy class**:
   ```ruby
   class MyStrategy < Otto::Security::Authentication::AuthStrategy
     def authenticate(env, requirement)
       # Validate credentials
       success_result(user_id: 'alice')  # or failure_result
     end
   end
   ```

2. **Register it in config.ru**:
   ```ruby
   app.add_auth_strategy('my_strategy', MyStrategy.new)
   ```

3. **Use it in routes**:
   ```
   GET  /protected  Controller#method  auth=my_strategy
   ```

## Next Steps

- Explore [Security Features](../security_features/) for CSRF, input validation, file uploads
- Review [Advanced Routes](../advanced_routes/) for response types and logic classes
- Check [Best Practices](../../docs/best-practices.md) for authentication patterns

## Further Reading

- [Architecture Guide](../../docs/architecture.md) - How authentication works
- [Best Practices](../../docs/best-practices.md) - Multi-strategy patterns
- [CLAUDE.md](../../CLAUDE.md#authentication-architecture) - Detailed auth documentation
- [Troubleshooting](../../docs/troubleshooting.md) - Auth debugging
