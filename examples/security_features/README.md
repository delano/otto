# Otto Security Features Example

This example demonstrates Otto's built-in security features, showing best practices for CSRF protection, input validation, file upload handling, and security headers.

## What You'll Learn

- Enabling and using CSRF protection
- Input validation for preventing injection attacks
- XSS prevention through output escaping
- Secure file upload handling with filename sanitization
- Adding security headers (CSP, HSTS, etc.)
- Request limiting to prevent denial-of-service
- Trusted proxy configuration for reverse proxies
- Privacy features (IP masking, user agent anonymization)

## Security Features Demonstrated

### CSRF Protection
All POST/PUT/DELETE requests include CSRF tokens in forms:
```ruby
<form method="post">
  <input type="hidden" name="_csrf_token" value="<%= @req.csrf_token %>">
  <input type="text" name="message">
</form>
```

### Input Validation
Server-side validation of user-submitted data:
- Length limits (max 1000 chars for messages)
- Character restrictions (no HTML tags)
- Required field validation
- Type validation

### XSS Prevention
All output is properly escaped:
```ruby
@res.body = "<h1>#{ERB::Util.html_escape(user_input)}</h1>"
```

### Secure File Uploads
File uploads are validated and sanitized:
- File type checking (whitelist approach)
- Size limits (prevent large uploads)
- Filename sanitization (remove path traversal)
- Safe storage location

### Security Headers
Automatic security headers are sent with responses:
- `Content-Security-Policy` - Prevents inline scripts
- `Strict-Transport-Security` - Enforces HTTPS
- `X-Frame-Options` - Prevents clickjacking
- `X-Content-Type-Options` - Prevents MIME sniffing

### Request Limiting
Configure limits to prevent DOS attacks:
- Maximum request size
- Maximum parameter keys
- Maximum parameter depth

### Trusted Proxies
Configure reverse proxy IPs for X-Forwarded-For headers:
```ruby
app.add_trusted_proxy('10.0.0.0/8')
app.add_trusted_proxy(/^192\.168\./)
```

### Privacy by Default
Automatic privacy features:
- Public IP masking (203.0.113.50 → 203.0.113.0)
- User agent anonymization (versions stripped)
- Country-level geo-location only
- Private/localhost IPs never masked

## How to Run

### Using rackup (recommended)

```sh
cd examples/security_features
rackup config.ru -p 10770
```

### Using thin

```sh
cd examples/security_features
thin -e dev -R config.ru -p 10770 start
```

Open your browser and navigate to `http://localhost:10770`.

## Testing Security Features

### XSS Prevention

Try entering `<script>alert("XSS")</script>` in form fields:
- The script tag is rendered as text, not executed
- You'll see it displayed as literal HTML tags
- Browser's developer tools show escaped HTML

### Input Validation

Test validation rules:
- Submit a message > 1000 characters (fails)
- Submit special characters like `<>` (fails)
- Submit valid text (succeeds)

### CSRF Protection

Examine form submissions:
- All POST forms include a `_csrf_token` hidden field
- Each request has a unique token
- Removing the token causes 403 Forbidden
- Browser's developer tools show token in form data

### File Uploads

Test file upload security:
- Try uploading an executable file (rejected)
- Try uploading a legitimate image (accepted)
- Check saved filename (sanitized, safe)
- Verify file permissions and location

### Security Headers

Check response headers:
- Open browser's Network tab in developer tools
- Click any response to view headers
- Look for security headers in response
- Visit `/headers` endpoint to see all headers

## Expected Output

### Successful Form Submission
```
POST /feedback HTTP/1.1
Content-Type: application/x-www-form-urlencoded

_csrf_token=abc123...
message=Hello+world

HTTP/1.1 302 Found
Location: http://localhost:10770/
Content-Security-Policy: default-src 'self'
Strict-Transport-Security: max-age=31536000
```

### Failed CSRF Validation
```
HTTP/1.1 403 Forbidden
Content-Type: text/plain

CSRF token validation failed
```

### Failed Input Validation
```
HTTP/1.1 400 Bad Request
Content-Type: text/plain

Message is too long (max 1000 characters)
```

### Security Headers Response
```
Content-Security-Policy: default-src 'self'
Strict-Transport-Security: max-age=31536000
X-Frame-Options: SAMEORIGIN
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
```

## File Structure

- `README.md`: This file
- `app.rb`: Main application logic with security implementations
  - Form validation and escaping
  - File upload handling
  - Header configuration
- `config.ru`: Rack configuration with security features enabled
- `routes`: URL routes mapped to SecureApp class methods

## Key Configuration

In `config.ru`:
```ruby
app = Otto.new("./routes")

# Enable security features
app.enable_csrf_protection!

# Configure request limits
app.security_config.request_size_limit = 1.megabyte
app.security_config.max_parameter_keys = 100
app.security_config.max_parameter_depth = 5

# Add trusted proxies if behind reverse proxy
app.add_trusted_proxy('10.0.0.0/8')

# Security headers
app.add_security_header('X-Custom-Header', 'value')
```

## Common Attack Scenarios

### XSS Attack
```javascript
<img src=x onerror="alert('XSS')">
```
**Result**: Safely displayed as text, not executed

### SQL Injection
```sql
'; DROP TABLE users; --
```
**Result**: Stored as literal text, invalid SQL

### Path Traversal
```
../../../../../../etc/passwd
```
**Result**: Filename sanitized to just `etc-passwd`

### Large Request
```
POST with 10MB body
```
**Result**: Rejected with 413 Payload Too Large

## Best Practices Demonstrated

1. **Defense in Depth**: Multiple layers of security
2. **Input Validation**: Whitelist approach (allow only safe input)
3. **Output Escaping**: Escape all user-controlled output
4. **CSRF Tokens**: Unique tokens for each request
5. **Security Headers**: Prevent common attack vectors
6. **File Upload Safety**: Validate type and sanitize names
7. **Request Limiting**: Prevent denial-of-service

## Testing with curl

```sh
# Test CSRF protection (will fail without token)
curl -X POST http://localhost:10770/feedback \
  -d "message=test"

# Test with valid CSRF token (get token from form first)
curl -X POST http://localhost:10770/feedback \
  -d "_csrf_token=<token>" \
  -d "message=test"

# Test input validation
curl -X POST http://localhost:10770/feedback \
  -d "message=$(python -c 'print(\"x\" * 2000)')"
```

## Next Steps

- Review the application code to see implementation details
- Explore [Best Practices](../../docs/best-practices.md) for security patterns
- Check [Troubleshooting](../../docs/troubleshooting.md) for common issues
- Read [Architecture Guide](../../docs/architecture.md) for security middleware details

## Further Reading

- [CLAUDE.md](../../CLAUDE.md#security-features) - Security configuration reference
- [Best Practices](../../docs/best-practices.md#security) - Security best practices
- [IP Privacy](../../CLAUDE.md#ip-privacy-privacy-by-default) - Privacy configuration
- [Troubleshooting](../../docs/troubleshooting.md#security-and-csrf) - Security troubleshooting
