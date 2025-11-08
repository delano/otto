#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Otto + Falcon SSE Integration
#
# This example demonstrates the RECOMMENDED approach for real-time
# communication with Otto: separate services connected via Redis pub/sub.
#
# Architecture:
# ┌─────────────────┐
# │   Otto API      │  ← Stateless HTTP (authentication, business logic)
# │   (Puma)        │
# └─────────────────┘
#         ↓
#    ┌─────────┐
#    │  Redis  │  ← Message queue (pub/sub)
#    │ Pub/Sub │
#    └─────────┘
#         ↓
# ┌─────────────────┐
# │  SSE Service    │  ← Stateful streaming (Falcon/Iodine)
# │  (Falcon)       │
# └─────────────────┘
#
# Benefits:
# - Independent scaling (scale SSE separately from API)
# - Technology choice (use best tool for each job)
# - Fault isolation (SSE crash doesn't affect API)
# - Clear separation of concerns (stateless vs stateful)

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'otto', path: '../' # Assuming this is in examples/
  gem 'falcon'
  gem 'async'
  gem 'async-http'
  gem 'redis'
  gem 'jwt'
  gem 'puma' # For Otto API
end

# ============================================================================
# Part 1: Otto API (Stateless HTTP)
# ============================================================================

# Routes file (routes.txt)
OTTO_ROUTES = <<~ROUTES
  # Authentication
  POST /api/auth/login                LoginLogic response=json

  # Publish events (authenticated users only)
  POST /api/events/publish            PublishEventLogic response=json auth=session

  # Get SSE token (for connecting to SSE service)
  GET  /api/events/token              SSETokenLogic response=json auth=session
ROUTES

# Logic classes
class LoginLogic < Otto::RequestContext
  def call
    # Simplified authentication (real implementation would check credentials)
    user_id = params[:user_id] || 1

    # Set session
    session[:user_id] = user_id

    # Generate JWT for SSE service
    sse_token = generate_sse_token(user_id)

    {
      success: true,
      user_id: user_id,
      sse_token: sse_token
    }
  end

  private

  def generate_sse_token(user_id)
    JWT.encode(
      { user_id: user_id, exp: Time.now.to_i + 3600 },
      ENV['JWT_SECRET'] || 'secret',
      'HS256'
    )
  end
end

class PublishEventLogic < Otto::RequestContext
  def call
    # Validate authenticated
    user_id = session[:user_id]
    raise_concern('Unauthorized', status: 401) unless user_id

    # Publish event to Redis (SSE service will pick it up)
    event_data = {
      type: params[:type] || 'notification',
      message: params[:message],
      timestamp: Time.now.iso8601
    }

    # Publish to user-specific channel
    redis.publish("events:user:#{user_id}", event_data.to_json)

    # Also publish to global channel if needed
    if params[:global]
      redis.publish('events:global', event_data.to_json)
    end

    { success: true, event: event_data }
  end

  private

  def redis
    @redis ||= Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')
  end
end

class SSETokenLogic < Otto::RequestContext
  def call
    user_id = session[:user_id]
    raise_concern('Unauthorized', status: 401) unless user_id

    # Generate short-lived token for SSE connection
    sse_token = JWT.encode(
      { user_id: user_id, exp: Time.now.to_i + 300 }, # 5 min expiry
      ENV['JWT_SECRET'] || 'secret',
      'HS256'
    )

    {
      success: true,
      token: sse_token,
      sse_url: ENV['SSE_SERVICE_URL'] || 'http://localhost:9292/stream'
    }
  end
end

# ============================================================================
# Part 2: Falcon SSE Service (Stateful Streaming)
# ============================================================================

require 'async'
require 'async/http/endpoint'
require 'falcon'
require 'redis'
require 'jwt'

class SSEService
  def initialize(redis_url: 'redis://localhost:6379/0', jwt_secret: 'secret')
    @redis_url = redis_url
    @jwt_secret = jwt_secret
  end

  def call(env)
    # Extract and verify token
    token = extract_token(env)
    user_id = verify_token(token)

    unless user_id
      return [401, { 'Content-Type' => 'application/json' }, ['{"error": "Unauthorized"}']]
    end

    # Setup SSE streaming
    stream_events(user_id)
  end

  private

  def extract_token(env)
    # Check Authorization header
    auth_header = env['HTTP_AUTHORIZATION']
    return auth_header.sub(/^Bearer /, '') if auth_header&.start_with?('Bearer ')

    # Check query parameter (less secure, but useful for EventSource)
    query = env['QUERY_STRING']
    params = Rack::Utils.parse_query(query)
    params['token']
  end

  def verify_token(token)
    return nil unless token

    payload = JWT.decode(token, @jwt_secret, true, { algorithm: 'HS256' })
    payload[0]['user_id']
  rescue JWT::DecodeError, JWT::ExpiredSignature
    nil
  end

  def stream_events(user_id)
    # Create Redis connection for this client
    redis = Redis.new(url: @redis_url)
    user_channel = "events:user:#{user_id}"
    global_channel = 'events:global'

    # Create streaming body
    body = Enumerator.new do |yielder|
      # Send initial connection message
      yielder << "event: connected\n"
      yielder << "data: {\"user_id\": #{user_id}}\n\n"

      # Heartbeat thread (keep connection alive)
      heartbeat_thread = Thread.new do
        loop do
          sleep 30
          yielder << ":heartbeat\n\n"
        rescue IOError
          break # Connection closed
        end
      end

      begin
        # Subscribe to user's channel and global channel
        redis.subscribe(user_channel, global_channel) do |on|
          on.subscribe do |channel, _subscriptions|
            yielder << "event: subscribed\n"
            yielder << "data: {\"channel\": \"#{channel}\"}\n\n"
          end

          on.message do |channel, message|
            # Parse message
            data = JSON.parse(message)
            event_type = data['type'] || 'message'

            # Send SSE event
            yielder << "event: #{event_type}\n"
            yielder << "data: #{message}\n\n"
          rescue JSON::ParserError
            # Invalid JSON, send as-is
            yielder << "data: #{message}\n\n"
          end
        end
      rescue IOError, Errno::EPIPE
        # Connection closed by client
      ensure
        heartbeat_thread.kill if heartbeat_thread&.alive?
        redis.quit
      end
    end

    # Return SSE response
    [200, {
      'Content-Type' => 'text/event-stream',
      'Cache-Control' => 'no-cache',
      'Connection' => 'keep-alive',
      'X-Accel-Buffering' => 'no' # Disable nginx buffering
    }, body]
  end
end

# ============================================================================
# Part 3: Running the Services
# ============================================================================

if __FILE__ == $PROGRAM_NAME
  puts "Otto + Falcon SSE Integration Example"
  puts "=" * 80
  puts

  service = ARGV[0]

  case service
  when 'otto'
    puts "Starting Otto API server on http://localhost:4567"
    puts "Routes:"
    puts OTTO_ROUTES
    puts

    # Write routes to temp file
    require 'tempfile'
    routes_file = Tempfile.new(['routes', '.txt'])
    routes_file.write(OTTO_ROUTES)
    routes_file.close

    # Initialize Otto
    otto = Otto.new(routes_file.path)
    otto.enable_sessions!(secret: 'dev_secret')

    # Run with Puma (or any Rack server)
    require 'rack'
    Rack::Handler::Puma.run(otto, Port: 4567, Threads: '0:4')

  when 'sse'
    puts "Starting Falcon SSE service on http://localhost:9292"
    puts "Channels:"
    puts "  - events:user:{user_id} (user-specific events)"
    puts "  - events:global (broadcast to all)"
    puts

    # Run with Falcon
    # Note: In production, use config.ru and `falcon serve`
    sse_service = SSEService.new(
      redis_url: ENV['REDIS_URL'] || 'redis://localhost:6379/0',
      jwt_secret: ENV['JWT_SECRET'] || 'secret'
    )

    # Simple Rack app wrapper
    app = lambda { |env| sse_service.call(env) }

    # Run with Falcon
    require 'async/reactor'
    require 'async/http/server'
    require 'async/io/host_endpoint'

    Async do
      endpoint = Async::IO::Endpoint.tcp('localhost', 9292)
      server = Async::HTTP::Server.new(app, endpoint)
      server.run
    end

  else
    puts "Usage:"
    puts "  ruby #{__FILE__} otto    # Start Otto API server (port 4567)"
    puts "  ruby #{__FILE__} sse     # Start SSE service (port 9292)"
    puts
    puts "Example workflow:"
    puts
    puts "Terminal 1: Start Redis"
    puts "  $ redis-server"
    puts
    puts "Terminal 2: Start Otto API"
    puts "  $ ruby #{__FILE__} otto"
    puts
    puts "Terminal 3: Start SSE service"
    puts "  $ ruby #{__FILE__} sse"
    puts
    puts "Terminal 4: Test the integration"
    puts "  # Login and get SSE token"
    puts "  $ curl -X POST http://localhost:4567/api/auth/login \\"
    puts "      -H 'Content-Type: application/json' \\"
    puts "      -d '{\"user_id\": 1}' \\"
    puts "      -c cookies.txt"
    puts
    puts "  # Get SSE token"
    puts "  $ curl -X GET http://localhost:4567/api/events/token \\"
    puts "      -b cookies.txt"
    puts "  # => {\"success\": true, \"token\": \"eyJ...\", \"sse_url\": \"...\"}"
    puts
    puts "  # Connect to SSE stream (in browser or with curl)"
    puts "  $ curl -N http://localhost:9292/stream?token=eyJ..."
    puts
    puts "  # Publish event (in another terminal)"
    puts "  $ curl -X POST http://localhost:4567/api/events/publish \\"
    puts "      -H 'Content-Type: application/json' \\"
    puts "      -d '{\"type\": \"notification\", \"message\": \"Hello SSE!\"}' \\"
    puts "      -b cookies.txt"
    puts
    puts "HTML Client Example:"
    puts <<~HTML
      <script>
        // 1. Login and get SSE token
        fetch('http://localhost:4567/api/auth/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ user_id: 1 }),
          credentials: 'include'
        })
        .then(res => res.json())
        .then(data => {
          // 2. Get SSE token
          return fetch('http://localhost:4567/api/events/token', {
            credentials: 'include'
          });
        })
        .then(res => res.json())
        .then(data => {
          // 3. Connect to SSE stream
          const eventSource = new EventSource(
            `http://localhost:9292/stream?token=${data.token}`
          );

          eventSource.addEventListener('connected', (e) => {
            console.log('Connected:', JSON.parse(e.data));
          });

          eventSource.addEventListener('notification', (e) => {
            console.log('Notification:', JSON.parse(e.data));
          });

          eventSource.onerror = (e) => {
            console.error('SSE error:', e);
          };

          // 4. Publish event (e.g., from button click)
          document.getElementById('send-btn').addEventListener('click', () => {
            fetch('http://localhost:4567/api/events/publish', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                type: 'notification',
                message: 'Hello from browser!'
              }),
              credentials: 'include'
            });
          });
        });
      </script>
    HTML
    puts
    exit 1
  end
end

# ============================================================================
# Part 4: Production Deployment
# ============================================================================

# Production config.ru for Otto API
OTTO_CONFIG_RU = <<~RUBY
  # Otto API - config.ru (deploy with Puma)

  require 'otto'
  require 'redis'
  require 'jwt'

  # Load logic classes
  require_relative 'lib/logic/login_logic'
  require_relative 'lib/logic/publish_event_logic'
  require_relative 'lib/logic/sse_token_logic'

  # Initialize Otto
  otto = Otto.new('routes.txt')
  otto.enable_sessions!(secret: ENV['SESSION_SECRET'])
  otto.enable_csrf_protection!
  otto.add_trusted_proxy(ENV['TRUSTED_PROXY']) if ENV['TRUSTED_PROXY']

  run otto
RUBY

# Production config.ru for SSE service
SSE_CONFIG_RU = <<~RUBY
  # SSE Service - sse_config.ru (deploy with Falcon)

  require 'async'
  require 'redis'
  require 'jwt'
  require_relative 'lib/sse_service'

  sse_service = SSEService.new(
    redis_url: ENV['REDIS_URL'],
    jwt_secret: ENV['JWT_SECRET']
  )

  run sse_service
RUBY

# Production deployment instructions
PRODUCTION_DEPLOYMENT = <<~MARKDOWN
  # Production Deployment

  ## Architecture

  ```
  Internet → Nginx (443) → Load Balancer
                              ├─→ Otto API (Puma cluster)
                              │   └─→ Redis (pub/sub)
                              └─→ SSE Service (Falcon cluster)
  ```

  ## 1. Deploy Otto API

  ### Puma config (config/puma.rb)
  ```ruby
  workers ENV.fetch('WEB_CONCURRENCY', 4)
  threads_count = ENV.fetch('RAILS_MAX_THREADS', 5)
  threads threads_count, threads_count

  port ENV.fetch('PORT', 3000)
  environment ENV.fetch('RACK_ENV', 'production')

  preload_app!

  on_worker_boot do
    # Redis connection pool per worker
    Redis.current = Redis.new(url: ENV['REDIS_URL'])
  end
  ```

  ### Run Otto API
  ```bash
  $ bundle exec puma -C config/puma.rb
  ```

  ## 2. Deploy SSE Service

  ### Falcon config (falcon.rb)
  ```ruby
  load :rack, :self_signed_tls, :supervisor

  rack 'sse_service', :self_signed_tls do
    scheme 'https'
    protocol :http1 # SSE requires HTTP/1.1
  end

  supervisor
  ```

  ### Run SSE service
  ```bash
  $ bundle exec falcon --config falcon.rb
  ```

  ## 3. Nginx Configuration

  ```nginx
  # Otto API (stateless HTTP)
  upstream otto_api {
    least_conn;
    server localhost:3000;
    server localhost:3001;
    server localhost:3002;
  }

  # SSE Service (stateful streaming)
  upstream sse_service {
    # IP hash for sticky sessions (keep client on same server)
    ip_hash;
    server localhost:9292;
    server localhost:9293;
    server localhost:9294;
  }

  server {
    listen 443 ssl http2;
    server_name api.example.com;

    # Otto API routes
    location /api/ {
      proxy_pass http://otto_api;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    # SSE Service routes
    location /stream {
      proxy_pass http://sse_service;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header Connection '';
      proxy_http_version 1.1;
      chunked_transfer_encoding off;
      proxy_buffering off;
      proxy_cache off;
      proxy_read_timeout 1h;
    }
  }
  ```

  ## 4. Redis Configuration

  ### High-availability Redis (Sentinel)
  ```yaml
  # redis.conf
  bind 127.0.0.1
  port 6379
  maxmemory 2gb
  maxmemory-policy allkeys-lru

  # Enable persistence (optional, but recommended)
  save 900 1
  save 300 10
  save 60 10000
  ```

  ## 5. Monitoring

  ### SSE Connection Metrics
  - Active connections per server
  - Subscription count (Redis PUBSUB NUMSUB)
  - Message publish rate
  - Connection duration

  ### Otto API Metrics
  - Request rate
  - Response time
  - Error rate
  - Redis publish latency

  ## 6. Scaling

  ### Horizontal Scaling (Otto API)
  - Stateless design enables unlimited horizontal scaling
  - Add more Puma workers behind load balancer
  - No session affinity required

  ### Horizontal Scaling (SSE Service)
  - Use Redis pub/sub for cross-server messaging
  - IP hash or cookie-based sticky sessions
  - Monitor connection distribution across servers

  ### Zero-Downtime Deploys
  - Otto API: Rolling restart (stateless, no connection drain needed)
  - SSE Service: Graceful shutdown with connection drain (30s timeout)

  ## 7. Security

  ### SSE Token Security
  - Short-lived tokens (5-10 min expiry)
  - Rotate JWT secret regularly
  - Use HTTPS for token transmission
  - Validate token on every SSE connection

  ### Rate Limiting
  - Otto API: Use Otto's built-in rate limiting
  - SSE Service: Limit connections per IP (nginx limit_conn)

  ### CORS
  - Configure CORS headers for cross-origin SSE
  - Whitelist specific origins
  - Use credentials: 'include' for authentication
MARKDOWN
