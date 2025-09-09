require 'otto'
require 'json'

class HelpersDemo
  def initialize(req, res)
    @req = req
    @res = res
  end

  attr_reader :req, :res

  def index
    res.headers['content-type'] = 'text/html'
    res.body = <<~HTML
      <h1>Otto Request & Response Helpers Demo</h1>
      <p>This demo shows Otto's built-in request and response helpers.</p>

      <h2>Available Demos:</h2>
      <ul>
        <li><a href="/request-info">Request Information</a> - Shows client IP, user agent, security info</li>
        <li><a href="/locale-demo?locale=es">Locale Detection</a> - Demonstrates locale detection and configuration</li>
        <li><a href="/secure-cookie">Secure Cookies</a> - Sets secure cookies with proper options</li>
        <li><a href="/headers">Response Headers</a> - Shows security headers and custom headers</li>
        <li>
          <form method="POST" action="/csp-demo">
            <button type="submit">CSP Headers Demo</button> - Content Security Policy with nonce
          </form>
        </li>
      </ul>

      <h2>Try These URLs:</h2>
      <ul>
        <li><a href="/locale-demo?locale=fr">French locale</a></li>
        <li><a href="/locale-demo?locale=invalid">Invalid locale (falls back to default)</a></li>
      </ul>
    HTML
  end

  def request_info
    # Demonstrate request helpers
    info = {
      'Client IP' => req.client_ipaddress,
      'User Agent' => req.user_agent,
      'HTTP Host' => req.http_host,
      'Server Name' => req.current_server_name,
      'Request Path' => req.request_path,
      'Request URI' => req.request_uri,
      'Is Local?' => req.local?,
      'Is Secure?' => req.secure?,
      'Is AJAX?' => req.ajax?,
      'Current Absolute URI' => req.current_absolute_uri,
      'Request Method' => req.request_method,
    }

    # Show collected proxy headers
    proxy_headers = req.collect_proxy_headers(
      header_prefix: 'X_DEMO_',
      additional_keys: %w[HTTP_ACCEPT HTTP_ACCEPT_LANGUAGE]
    )

    # Format request details for logging
    request_details = req.format_request_details(header_prefix: 'X_DEMO_')

    res.headers['content-type'] = 'text/html'
    res.body = <<~HTML
      <h1>Request Information</h1>
      <p><a href="/">← Back to index</a></p>

      <h2>Basic Request Info:</h2>
      <table border="1" style="border-collapse: collapse;">
        #{info.map { |k, v| "<tr><td><strong>#{k}</strong></td><td>#{v}</td></tr>" }.join("\n        ")}
      </table>

      <h2>Proxy Headers:</h2>
      <pre>#{proxy_headers}</pre>

      <h2>Formatted Request Details (for logging):</h2>
      <pre>#{request_details}</pre>

      <h2>Application Path Helper:</h2>
      <p>App path for ['api', 'v1', 'users']: <code>#{req.app_path('api', 'v1', 'users')}</code></p>
    HTML
  end

  def locale_demo
    # Demonstrate locale detection with Otto configuration
    current_locale = req.check_locale!(req.params['locale'], {
                                         preferred_locale: 'es', # Simulate user preference
      locale_env_key: 'demo.locale',
      debug: true,
                                       })

    # Show what was stored in environment
    stored_locale = req.env['demo.locale']

    res.headers['content-type'] = 'text/html'
    res.body = <<~HTML
      <h1>Locale Detection Demo</h1>
      <p><a href="/">← Back to index</a></p>

      <h2>Locale Detection Results:</h2>
      <table border="1" style="border-collapse: collapse;">
        <tr><td><strong>Detected Locale</strong></td><td>#{current_locale}</td></tr>
        <tr><td><strong>Stored in Environment</strong></td><td>#{stored_locale}</td></tr>
        <tr><td><strong>Query Parameter</strong></td><td>#{req.params['locale'] || 'none'}</td></tr>
        <tr><td><strong>Accept-Language Header</strong></td><td>#{req.env['HTTP_ACCEPT_LANGUAGE'] || 'none'}</td></tr>
      </table>

      <h2>Locale Sources (in precedence order):</h2>
      <ol>
        <li>URL Parameter: <code>?locale=#{req.params['locale'] || 'none'}</code></li>
        <li>User Preference: <code>es</code> (simulated)</li>
        <li>Rack Locale: <code>#{req.env['rack.locale']&.first || 'none'}</code></li>
        <li>Default: <code>en</code></li>
      </ol>

      <h2>Try Different Locales:</h2>
      <ul>
        <li><a href="/locale-demo?locale=en">English (en)</a></li>
        <li><a href="/locale-demo?locale=es">Spanish (es)</a></li>
        <li><a href="/locale-demo?locale=fr">French (fr)</a></li>
        <li><a href="/locale-demo?locale=invalid">Invalid locale</a></li>
        <li><a href="/locale-demo">No locale parameter</a></li>
      </ul>
    HTML
  end

  def secure_cookie
    # Demonstrate secure cookie helpers
    res.send_secure_cookie('demo_secure', 'secure_value_123', 3600, {
                             path: '/helpers_demo',
      secure: !req.local?, # Only secure in production
      same_site: :strict,
                           })

    res.send_session_cookie('demo_session', 'session_value_456', {
                              path: '/helpers_demo',
                            })

    res.headers['content-type'] = 'text/html'
    res.body = <<~HTML
      <h1>Secure Cookies Demo</h1>
      <p><a href="/">← Back to index</a></p>

      <h2>Cookies Set:</h2>
      <ul>
        <li><strong>demo_secure</strong> - Secure cookie with 1 hour TTL</li>
        <li><strong>demo_session</strong> - Session cookie (no expiration)</li>
      </ul>

      <h2>Cookie Security Features:</h2>
      <ul>
        <li>Secure flag (HTTPS only in production)</li>
        <li>HttpOnly flag (prevents XSS access)</li>
        <li>SameSite=Strict (CSRF protection)</li>
        <li>Proper expiration handling</li>
      </ul>

      <p>Check your browser's developer tools to see the cookie headers!</p>
    HTML
  end

  def csp_demo
    # Demonstrate CSP headers with nonce
    nonce = SecureRandom.base64(16)

    res.send_csp_headers('text/html; charset=utf-8', nonce, {
                           development_mode: req.local?,
      debug: true,
                         })

    res.body = <<~HTML
      <h1>Content Security Policy Demo</h1>
      <p><a href="/">← Back to index</a></p>

      <h2>CSP Header Generated</h2>
      <p>This page includes a CSP header with a nonce. Check the response headers!</p>

      <h2>Nonce Value:</h2>
      <p><code>#{nonce}</code></p>

      <h2>Inline Script with Nonce:</h2>
      <script nonce="#{nonce}">
        console.log('This script runs because it has the correct nonce!');
        document.addEventListener('DOMContentLoaded', function() {
          document.getElementById('nonce-demo').innerHTML = 'Nonce verification successful!';
        });
      </script>

      <div id="nonce-demo" style="padding: 10px; background: #d4edda; border: 1px solid #c3e6cb; color: #155724;">
        Loading...
      </div>

      <p><strong>Note:</strong> Without the nonce, inline scripts would be blocked by CSP.</p>
    HTML
  end

  def show_headers
    # Demonstrate response headers and security features
    res.set_cookie('demo_header', {
                     value: 'header_demo_value',
      max_age: 1800,
      secure: !req.local?,
      httponly: true,
                   })

    # Add cache control
    res.no_cache!

    # Get security headers that would be added
    security_headers = res.cookie_security_headers

    res.headers['content-type'] = 'text/html'
    res.headers['X-Demo-Header'] = 'Custom header value'

    res.body = <<~HTML
      <h1>Response Headers Demo</h1>
      <p><a href="/">← Back to index</a></p>

      <h2>Custom Headers Set:</h2>
      <ul>
        <li><strong>X-Demo-Header:</strong> Custom header value</li>
        <li><strong>Cache-Control:</strong> no-store, no-cache, must-revalidate, max-age=0</li>
        <li><strong>Set-Cookie:</strong> demo_header (with security options)</li>
      </ul>

      <h2>Security Headers Available:</h2>
      <table border="1" style="border-collapse: collapse;">
        #{security_headers.map { |k, v| "<tr><td><strong>#{k}</strong></td><td>#{v}</td></tr>" }.join("\n        ")}
      </table>

      <p>Use your browser's developer tools to inspect all response headers!</p>
    HTML
  end

  def not_found
    res.status = 404
    res.headers['content-type'] = 'text/html'
    res.body = <<~HTML
      <h1>404 - Page Not Found</h1>
      <p><a href="/">← Back to index</a></p>
      <p>This is a custom 404 page demonstrating error handling.</p>
    HTML
  end
end
