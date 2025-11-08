# Otto Streaming Architecture Analysis: SSE and WebSocket Support

**Author**: Claude Code Investigation
**Date**: 2025-11-08
**Scope**: Analysis of Server-Sent Events (SSE) and WebSocket support in Otto framework

---

## Executive Summary

After comprehensive analysis of Otto's architecture and modern web framework patterns, **I recommend NOT integrating SSE/WebSocket support directly into Otto's core**. Instead, I recommend a **separation of concerns** approach where streaming functionality is handled by dedicated services or separate routing layers.

**Key Findings**:
- SSE and WebSocket are fundamentally incompatible with Otto's stateless, synchronous request/response model
- Modern frameworks (Rails, Sinatra, Roda) either run streaming as separate processes or require async server infrastructure
- Best practice is to separate real-time communication from REST API routing
- Otto should remain focused on stateless HTTP APIs with clear security guarantees

---

## 1. Current State: Otto's Architecture

### 1.1 Request/Response Lifecycle

Otto uses a **fully synchronous, stateless** request/response model:

```
HTTP Request
  → Middleware IN (IPPrivacy, CSRF, RateLimit, Validation)
  → Route Matching (static → literal → dynamic → 404)
  → RouteAuthWrapper (per-route authentication)
  → Handler Execution (Logic class, instance method, or class method)
  → Response Handler (JSON, View, Redirect, Auto, Default)
  → Middleware OUT
  → HTTP Response (complete, connection closed)
```

### 1.2 Response Handler System

Otto's response handling is based on the `response=` parameter:

```ruby
# lib/otto/route_handlers/base.rb:97-103
handler_class = case response_type
  in 'json' then Otto::ResponseHandlers::JSONHandler
  in 'redirect' then Otto::ResponseHandlers::RedirectHandler
  in 'view' then Otto::ResponseHandlers::ViewHandler
  in 'auto' then Otto::ResponseHandlers::AutoHandler
  else Otto::ResponseHandlers::DefaultHandler
end

handler_class.handle(result, response, context)
```

**Current handlers generate complete responses**:

```ruby
# lib/otto/response_handlers/json.rb:18-33
response['Content-Type'] = 'application/json'
response.body = [JSON.generate(data)]
ensure_status_set(response, context[:status_code] || 200)
```

The response body is **always an array** (`[JSON.generate(data)]`), finalized via:

```ruby
# lib/otto/route_handlers/base.rb:85-86
res.body = [res.body] unless res.body.respond_to?(:each)
res.finish
```

### 1.3 Key Architectural Characteristics

1. **Stateless**: Each request is independent, no connection state maintained
2. **Synchronous**: Handler executes, response generated, connection closed
3. **Frozen Configuration**: All security config frozen after first request (prevents runtime bypasses)
4. **Thread-Safe**: Designed for concurrent requests with isolated contexts
5. **Privacy by Default**: IP masking, geo-location, anonymization happen in middleware
6. **Security First**: CSRF, validation, rate limiting, error handler registration

---

## 2. Technical Requirements: SSE and WebSocket

### 2.1 Server-Sent Events (SSE)

**Protocol**: HTTP-based unidirectional streaming (server → client)

**Technical Requirements**:
- Keep HTTP connection open indefinitely
- Stream data in `text/event-stream` format
- Requires Rack streaming response body (Rack 3+)
- Needs async server (Falcon, Puma with threaded mode, Iodine)

**Rack 3 Streaming Format**:
```ruby
# Modern Rack 3 approach
[200,
 {'Content-Type' => 'text/event-stream'},
 streaming_body_enumerator]
```

**SSE Example**:
```ruby
def sse_handler
  stream = lambda do |out|
    10.times do |i|
      out << "data: #{i}\n\n"
      sleep 1
    end
    out.close
  end

  [200, {'Content-Type' => 'text/event-stream'}, stream]
end
```

### 2.2 WebSocket

**Protocol**: Bidirectional, full-duplex communication over TCP

**Technical Requirements**:
- HTTP upgrade handshake (101 Switching Protocols)
- Persistent TCP connection (not HTTP request/response)
- Requires Rack hijack API (`rack.hijack`, `rack.hijack_io`)
- Needs async server with WebSocket support (Falcon, Iodine, Puma)
- Frame-based binary protocol (not HTTP)

**Rack Hijack Example**:
```ruby
def websocket_handler(env)
  if Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)

    ws.on :message do |event|
      ws.send(event.data)
    end

    ws.on :close do |event|
      ws = nil
    end

    ws.rack_response
  else
    [400, {}, ['Expected WebSocket connection']]
  end
end
```

---

## 3. Industry Patterns: How Other Frameworks Handle Streaming

### 3.1 Rails ActionCable (WebSocket)

**Architecture**: **Separate process/server** from main Rails app

```ruby
# config/cable.yml
production:
  adapter: redis
  url: redis://localhost:6379/1
  channel_prefix: myapp_production

# Separate ActionCable server process
# bin/cable
#!/usr/bin/env ruby
require_relative '../config/environment'
Rails::ActionCable::Server.start
```

**Key Insights**:
- ActionCable runs as **standalone process** (separate from Puma/Unicorn)
- Uses **Redis pub/sub** for message queue (stateless app servers)
- Rails app pushes to Redis, ActionCable streams to clients
- **Separation of concerns**: HTTP API ≠ WebSocket server

**Why Separate?**:
- Different scaling characteristics (long-lived vs short-lived connections)
- Different server requirements (async vs sync)
- Stateful WebSocket connections don't fit stateless Rails app model

### 3.2 Sinatra (SSE)

**Architecture**: **Requires async server** (Thin, Rainbows, Falcon)

```ruby
# Gemfile
gem 'sinatra'
gem 'thin'  # EventMachine-based async server

# app.rb
require 'sinatra'
require 'sinatra/streaming'

get '/stream' do
  content_type 'text/event-stream'
  stream(:keep_open) do |out|
    EventMachine.add_periodic_timer(1) do
      out << "data: #{Time.now}\n\n"
    end
  end
end

# Run with Thin (NOT WEBrick/Puma)
# thin start -p 4567
```

**Key Insights**:
- **Must use EventMachine-based server** (Thin, Rainbows)
- Cannot use blocking servers (WEBrick, Mongrel)
- Sinatra's `streaming` plugin abstracts async complexity
- **Server dependency**: Framework requires specific infrastructure

### 3.3 Roda (SSE)

**Architecture**: **Streaming plugin** with async option

```ruby
plugin :streaming

route do |r|
  r.get 'stream' do
    response['Content-Type'] = 'text/event-stream'

    # Async streaming in separate thread
    stream(async: true, loop: true) do |out|
      out << "data: #{Time.now}\n\n"
      sleep 1
    end
  end
end
```

**Key Insights**:
- Roda provides **plugin-based streaming** support
- `async: true` runs stream block in **separate thread**
- Uses `SizedQueue` for inter-thread communication
- **Still requires async server** (Falcon, Iodine) for production

### 3.4 Go (Gin/Echo) WebSocket

**Architecture**: **Route-level handler upgrade**

```go
// Gin framework
router := gin.Default()

// WebSocket route
router.GET("/ws", func(c *gin.Context) {
    upgrader := websocket.Upgrader{}
    conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
    if err != nil {
        return
    }
    defer conn.Close()

    // Handle WebSocket connection
    for {
        messageType, p, err := conn.ReadMessage()
        if err != nil {
            return
        }
        conn.WriteMessage(messageType, p)
    }
})
```

**Key Insights**:
- WebSocket handlers **coexist with HTTP routes** (same router)
- Go's goroutines enable **cheap concurrency** (not possible in Ruby)
- HTTP/2 and WebSocket support built into standard library
- **Language advantage**: Go's async model ≠ Ruby's threading model

### 3.5 Node.js (Express + Socket.IO)

**Architecture**: **Separate Socket.IO server** attached to HTTP server

```javascript
const express = require('express');
const http = require('http');
const socketIO = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = socketIO(server);

// Regular HTTP routes
app.get('/api/users', (req, res) => {
  res.json({ users: [] });
});

// WebSocket namespace (separate from HTTP routing)
io.on('connection', (socket) => {
  socket.on('message', (data) => {
    io.emit('message', data);
  });
});

server.listen(3000);
```

**Key Insights**:
- Socket.IO is **separate layer** from Express routing
- Same HTTP server, **different routing/handling logic**
- Node's event loop enables async by default
- **Architectural separation**: HTTP routes ≠ WebSocket events

---

## 4. Compatibility Analysis: SSE/WebSocket vs. Otto's Design

### 4.1 Fundamental Incompatibilities

| Otto Design Principle | SSE/WebSocket Requirement | Compatibility |
|----------------------|--------------------------|---------------|
| **Stateless request/response** | Long-lived stateful connections | ❌ Incompatible |
| **Synchronous handlers** | Async streaming enumerators | ❌ Incompatible |
| **Response finalized immediately** | Keep connection open indefinitely | ❌ Incompatible |
| **Thread-safe isolated contexts** | Shared connection state | ⚠️ Complex |
| **Frozen security config** | Runtime streaming config | ⚠️ Must freeze before first request |
| **Privacy by default (IP masking)** | Long-lived connection tracking | ⚠️ Can work but complex |
| **JSON/View/Redirect responses** | Streaming enumerator responses | ❌ Incompatible |

### 4.2 Technical Barriers

#### 4.2.1 Response Handler Architecture

**Current**: All response handlers generate **complete, finalized** responses:

```ruby
# lib/otto/response_handlers/json.rb
response.body = [JSON.generate(data)]
ensure_status_set(response, 200)
```

**Required for SSE**: Streaming enumerable that yields data over time:

```ruby
# Hypothetical SSE handler
response.body = Enumerator.new do |yielder|
  loop do
    yielder << "data: #{Time.now}\n\n"
    sleep 1
  end
end
```

**Problem**: Otto's `finalize_response` expects array-like body:

```ruby
# lib/otto/route_handlers/base.rb:85
res.body = [res.body] unless res.body.respond_to?(:each)
```

This would **wrap the enumerator in an array**, breaking streaming.

#### 4.2.2 Middleware Stack

**Current**: Middleware runs **before and after** handler execution:

```
IPPrivacyMiddleware IN
  → CSRFMiddleware IN
    → RateLimitMiddleware IN
      → Handler (complete response generated)
    ← RateLimitMiddleware OUT
  ← CSRFMiddleware OUT
← IPPrivacyMiddleware OUT
```

**Problem for SSE**: Once streaming starts, middleware cannot "unwind" because **connection is still open**:

```
IPPrivacyMiddleware IN
  → CSRFMiddleware IN
    → RateLimitMiddleware IN
      → SSE Handler (starts streaming)
        → [Connection stays open for minutes/hours]
        → [Middleware stack never unwinds]
```

**Consequences**:
- CSRF tokens can't be refreshed mid-stream
- Rate limiting can't be updated during stream
- IP privacy middleware can't re-mask IPs (not that it needs to)
- Error handling becomes complex (stream already started)

#### 4.2.3 Server Requirements

**Current**: Otto is **server-agnostic** (works with Puma, Unicorn, Passenger, WEBrick)

**Required**: SSE/WebSocket need **async servers**:

| Server | SSE Support | WebSocket Support | Notes |
|--------|-------------|-------------------|-------|
| **Falcon** | ✅ Full | ✅ Full | Fiber-based, async-http |
| **Iodine** | ✅ Full | ✅ Full | C extension, async I/O |
| **Puma** | ⚠️ Partial | ⚠️ Partial | Threaded mode only, not optimal |
| **Unicorn** | ❌ No | ❌ No | Pre-fork, synchronous |
| **Passenger** | ⚠️ Partial | ⚠️ Partial | Threaded mode only |
| **WEBrick** | ❌ No | ❌ No | Single-threaded |

**Problem**: Adding SSE/WebSocket would **force server choice**, breaking server-agnostic design.

#### 4.2.4 Scaling and State Management

**Current**: Otto apps scale horizontally (stateless load balancing):

```
            Load Balancer
           /      |      \
      Otto-1   Otto-2   Otto-3
       (any)    (any)    (any)
```

**Required for WebSocket**: Sticky sessions or Redis pub/sub:

```
            Load Balancer (sticky sessions)
           /      |      \
      Otto-1   Otto-2   Otto-3
       (WS1)    (WS2)    (WS3)
         \      |      /
          Redis Pub/Sub
```

**Problem**: Stateful routing complicates:
- Load balancing (client must stay connected to same server)
- Zero-downtime deploys (existing connections must be drained)
- Horizontal scaling (connection state not shared)
- Rate limiting (per-server vs cluster-wide limits)

---

## 5. Best Practices and Anti-Patterns

### 5.1 Best Practices

#### ✅ **Separate Services for Real-Time Communication**

**Pattern**: Run SSE/WebSocket as dedicated service, separate from REST API

```
┌─────────────────┐
│   REST API      │  ← Otto (stateless HTTP)
│   (Otto)        │
└─────────────────┘
         ↓
    ┌─────────┐
    │  Redis  │  ← Message queue
    │ Pub/Sub │
    └─────────┘
         ↓
┌─────────────────┐
│  WebSocket      │  ← Separate Falcon/Iodine server
│  Service        │
└─────────────────┘
```

**Benefits**:
- Independent scaling (scale WebSocket separately from API)
- Technology choice (use best tool for each job)
- Fault isolation (WebSocket crash doesn't affect API)
- Clear separation of concerns (stateless vs stateful)

**Example (Rails ActionCable pattern)**:
```ruby
# Otto app pushes messages to Redis
class NotificationLogic < Otto::RequestContext
  def call
    Redis.current.publish('notifications', {
      user_id: params[:user_id],
      message: params[:message]
    }.to_json)

    { success: true }
  end
end

# Separate Falcon app consumes from Redis and streams via SSE
# falcon_sse.rb
require 'async'
require 'async/http/endpoint'
require 'async/websocket'
require 'redis'

class SSEHandler
  def call(env)
    redis = Redis.new

    body = Enumerator.new do |yielder|
      redis.subscribe('notifications') do |on|
        on.message do |channel, message|
          yielder << "data: #{message}\n\n"
        end
      end
    end

    [200, {'Content-Type' => 'text/event-stream'}, body]
  end
end
```

#### ✅ **Use HTTP/2 Server Push (Alternative to SSE for some use cases)**

**Pattern**: Server push for static assets, not dynamic data

```ruby
# Rack::EarlyHints for HTTP/2 push
# (Not a replacement for SSE, but useful for preloading)
def call(env)
  early_hints = {
    'Link' => '</styles.css>; rel=preload; as=style'
  }
  env['rack.early_hints'].call(early_hints)

  [200, {}, ['Body']]
end
```

**Benefits**:
- No connection state required
- Works with standard HTTP/2 servers
- Good for asset preloading, not real-time data

**Limitations**:
- Browser cache only, not bidirectional
- Not suitable for live updates

#### ✅ **Polling with Long-Polling for Simple Cases**

**Pattern**: Client polls Otto endpoint, Otto returns immediately or waits (long-polling)

```ruby
# Otto route
GET /api/notifications/poll NotificationLogic response=json

class NotificationLogic < Otto::RequestContext
  def call
    timeout = params[:timeout].to_i.clamp(1, 30)
    start_time = Time.now

    # Long-polling: wait for new data up to timeout
    loop do
      notifications = fetch_new_notifications(current_user.id)
      return { notifications: notifications } if notifications.any?

      break if Time.now - start_time > timeout
      sleep 0.5
    end

    { notifications: [] }
  end
end
```

**Benefits**:
- Works with Otto's synchronous model
- No streaming infrastructure required
- HTTP-based, cacheable, RESTful

**Limitations**:
- Not as efficient as SSE/WebSocket
- Increased latency (poll interval)
- More server load (repeated connections)

### 5.2 Anti-Patterns

#### ❌ **Mixing Stateless HTTP and Stateful WebSocket in Same Router**

**Problem**: Confuses architectural boundaries, complicates security

```ruby
# ANTI-PATTERN: Don't do this in Otto
GET  /api/users           UserLogic response=json          # Stateless
POST /api/users           CreateUserLogic response=json   # Stateless
GET  /api/stream          StreamLogic response=sse        # Stateful ← Doesn't fit
```

**Why Bad**:
- Security middleware (CSRF, rate limiting) designed for request/response
- Authentication strategies assume short-lived requests
- Error handling expects finalized responses
- Configuration freezing prevents runtime changes

#### ❌ **Using SSE/WebSocket for Simple Updates**

**Problem**: Over-engineering when polling suffices

**Example**: Dashboard metrics that update every 10 seconds

```ruby
# ANTI-PATTERN: SSE for low-frequency updates
GET /dashboard/metrics StreamLogic response=sse

# BETTER: Simple polling
GET /dashboard/metrics MetricsLogic response=json
# Client: setInterval(() => fetch('/dashboard/metrics'), 10000)
```

**When to Use SSE/WebSocket**:
- High-frequency updates (>1/second)
- Instant notification required (<100ms latency)
- Bidirectional communication needed (chat, multiplayer)

**When to Use Polling**:
- Low-frequency updates (<1/minute)
- Latency tolerance (seconds acceptable)
- Simple implementation preferred

#### ❌ **Implementing WebSocket Without Redis Pub/Sub (Multi-Server)**

**Problem**: Doesn't scale horizontally

```ruby
# ANTI-PATTERN: In-memory WebSocket state
class WebSocketHandler
  @@connections = []  # Stored in single server's memory

  def call(env)
    ws = Faye::WebSocket.new(env)
    @@connections << ws
    # Problem: Other servers don't see this connection
  end
end
```

**Why Bad**:
- Connections only exist on one server
- Can't broadcast across cluster
- Zero-downtime deploys fail (connections lost)

**Better**: Use Redis pub/sub for cross-server messaging (see ActionCable pattern above)

#### ❌ **Blocking Servers for Streaming**

**Problem**: Using Unicorn/Passenger for SSE ties up workers

```ruby
# ANTI-PATTERN: Unicorn with SSE
# config/unicorn.rb
worker_processes 4

# SSE route blocks worker for entire stream duration
# 10 concurrent SSE clients = 10 blocked workers (out of 4 total)
# Result: All workers blocked, no capacity for regular requests
```

**Why Bad**:
- Worker pool exhaustion
- Degrades HTTP API performance
- Creates cascading failures

**Better**: Separate SSE service on async server (Falcon, Iodine)

---

## 6. Recommendations for Otto

### 6.1 Primary Recommendation: **DO NOT INTEGRATE SSE/WebSocket into Otto Core**

**Rationale**:
1. **Architectural Mismatch**: Otto's stateless, synchronous design is fundamentally incompatible with streaming
2. **Server Coupling**: Would force users to specific async servers (Falcon, Iodine)
3. **Security Complexity**: Streaming breaks middleware assumptions (CSRF, rate limiting)
4. **Scaling Concerns**: Introduces stateful routing, complicates horizontal scaling
5. **Maintenance Burden**: Adds significant complexity for niche use case
6. **Clear Separation**: Industry best practice is separate services (ActionCable model)

### 6.2 Alternative Solutions

#### Option 1: **Document External Integration Pattern** (RECOMMENDED)

Create official guide for integrating Otto with separate streaming service:

```markdown
# Otto + Falcon SSE Integration Guide

## Architecture

- Otto: Stateless REST API (authentication, business logic)
- Falcon: SSE streaming service (real-time updates)
- Redis: Message queue (pub/sub)

## Setup

### 1. Otto API publishes events
# routes.txt
POST /api/events PublishEventLogic response=json auth=session

# lib/logic/publish_event_logic.rb
class PublishEventLogic < Otto::RequestContext
  def call
    Redis.current.publish('events', {
      event: params[:event],
      data: params[:data]
    }.to_json)
    { success: true }
  end
end

### 2. Falcon SSE service subscribes and streams
# sse_service.rb (separate process)
require 'async'
require 'falcon'
require 'redis'

class SSEService
  def call(env)
    redis = Redis.new

    body = Enumerator.new do |yielder|
      redis.subscribe('events') do |on|
        on.message do |channel, message|
          yielder << "data: #{message}\n\n"
        end
      end
    end

    [200, {'Content-Type' => 'text/event-stream'}, body]
  end
end

# Run with: falcon serve -b 0.0.0.0:9292
```

**Benefits**:
- Preserves Otto's design integrity
- Provides clear architectural guidance
- Supports advanced users who need streaming
- No core complexity added

#### Option 2: **Plugin System for Advanced Users**

Create **experimental** plugin interface (NOT in core):

```ruby
# Hypothetical (NOT recommended for core, but possible as plugin)

# otto-streaming-plugin gem (community-maintained)
class Otto
  module Plugins
    module Streaming
      def enable_streaming!
        # WARNING: Requires Falcon/Iodine server
        # WARNING: Breaks middleware guarantees
        # WARNING: Not compatible with frozen config
        @streaming_enabled = true
      end

      def sse_route(verb, path, handler)
        route = Otto::Route.new(verb, path, "#{handler} response=sse")
        # ... streaming-specific setup
      end
    end
  end
end

# User's app (opt-in, experimental)
otto.extend Otto::Plugins::Streaming
otto.enable_streaming!  # Must be called before first request

otto.sse_route(:GET, '/stream', 'StreamHandler')
```

**Benefits**:
- Keeps core clean
- Community can experiment
- Clear "experimental" status
- Users understand trade-offs

**Risks**:
- Still complicates Otto's architecture
- May give false impression it's "supported"
- Security implications unclear

#### Option 3: **Recommend Third-Party Solutions**

Document integrations with existing solutions:

**For SSE**:
- **Mercure**: Open-source SSE hub (Go-based, protocol spec)
- **Ably**: Commercial real-time messaging platform
- **Pusher**: Commercial WebSocket/SSE service

**For WebSocket**:
- **AnyCable**: Rails-compatible WebSocket server (Go/Rust)
- **Socket.IO**: Node.js-based (can integrate with Otto via message queue)
- **Phoenix Channels**: Elixir (if building new real-time service)

**Example Integration**:
```ruby
# Otto publishes to Mercure
POST /api/.well-known/mercure MercurePublishLogic response=json

class MercurePublishLogic < Otto::RequestContext
  def call
    # Publish to Mercure hub (separate service)
    HTTParty.post('http://mercure-hub/.well-known/mercure', {
      body: {
        topic: params[:topic],
        data: params[:data]
      },
      headers: {
        'Authorization' => "Bearer #{ENV['MERCURE_JWT']}"
      }
    })

    { success: true }
  end
end

# Client subscribes to Mercure hub directly
# <script>
#   const eventSource = new EventSource('http://mercure-hub/.well-known/mercure?topic=notifications');
#   eventSource.onmessage = (e) => console.log(e.data);
# </script>
```

---

## 7. Conclusion

### 7.1 Summary

**SSE and WebSocket are fundamentally incompatible with Otto's design philosophy**:

- Otto: Stateless, synchronous, request/response, frozen security, server-agnostic
- SSE/WebSocket: Stateful, async, long-lived connections, runtime state, server-specific

**Industry consensus**: Separate real-time communication from REST APIs

- Rails: ActionCable runs as separate process
- Node.js: Socket.IO is separate layer from Express
- Go: Goroutines enable coexistence (not applicable to Ruby)

### 7.2 Final Recommendation

**For Otto Project**:

1. ✅ **Do NOT add SSE/WebSocket to core**
   - Preserves architectural integrity
   - Avoids server coupling
   - Maintains security guarantees

2. ✅ **Document external integration patterns**
   - Otto + Falcon/Iodine SSE service
   - Otto + Redis + AnyCable
   - Otto + Mercure hub

3. ✅ **Recommend long-polling for simple cases**
   - Works with Otto's synchronous model
   - Good for low-frequency updates
   - Example implementation in docs

4. ⚠️ **Consider plugin system (if community demands)**
   - Clearly marked "experimental"
   - Requires async server
   - Security implications documented

**For Otto Users Who Need Real-Time**:

- **Low-frequency updates (<1/min)**: Use HTTP polling with Otto routes
- **Medium-frequency updates (1-10/sec)**: Separate Falcon SSE service + Redis
- **Bidirectional communication**: Separate WebSocket service (Falcon/AnyCable)
- **Commercial requirements**: Use Ably, Pusher, or similar managed service

### 7.3 Key Insight

**The question isn't "Can Otto support SSE/WebSocket?"** (technically possible with massive refactoring)

**The question is "Should Otto support SSE/WebSocket?"** (architecturally inadvisable)

Answer: **No**. Otto should remain focused on its strength: **stateless, secure, privacy-first HTTP APIs with clear architectural boundaries**.

---

## Appendix A: Code Examples

### A.1 Otto + Falcon SSE Integration (Full Example)

See `examples/otto_falcon_sse_integration.rb` for complete working example.

### A.2 Long-Polling Implementation in Otto

```ruby
# routes.txt
GET /api/notifications/poll NotificationPollLogic response=json auth=session

# lib/logic/notification_poll_logic.rb
class NotificationPollLogic < Otto::RequestContext
  def call
    timeout = params[:timeout].to_i.clamp(1, 30)
    last_id = params[:last_id].to_i
    start_time = Time.now

    loop do
      notifications = Notification.where(user_id: current_user.id)
                                  .where('id > ?', last_id)
                                  .order(id: :asc)
                                  .limit(10)

      if notifications.any?
        return {
          notifications: notifications.map(&:to_h),
          last_id: notifications.last.id
        }
      end

      # Check timeout
      break if Time.now - start_time > timeout

      # Wait before checking again (reduces CPU/DB load)
      sleep 0.5
    end

    # Timeout reached, return empty
    { notifications: [], last_id: last_id }
  end
end

# Client-side JavaScript
// async function pollNotifications() {
//   let lastId = 0;
//
//   while (true) {
//     try {
//       const response = await fetch(`/api/notifications/poll?timeout=30&last_id=${lastId}`);
//       const data = await response.json();
//
//       if (data.notifications.length > 0) {
//         data.notifications.forEach(notif => console.log(notif));
//         lastId = data.last_id;
//       }
//     } catch (error) {
//       console.error('Polling error:', error);
//       await new Promise(resolve => setTimeout(resolve, 5000)); // Wait 5s on error
//     }
//   }
// }
//
// pollNotifications();
```

### A.3 Separate Falcon SSE Service

```ruby
# sse_service.rb (separate process)
require 'async'
require 'async/http/endpoint'
require 'falcon'
require 'redis'

class SSEHandler
  def initialize(redis_url = 'redis://localhost:6379/0')
    @redis_url = redis_url
  end

  def call(env)
    # Authentication (verify token from Otto)
    token = env['HTTP_AUTHORIZATION']&.sub(/^Bearer /, '')
    user_id = verify_token(token)
    return [401, {}, ['Unauthorized']] unless user_id

    # Subscribe to user's channel
    redis = Redis.new(url: @redis_url)
    channel = "notifications:#{user_id}"

    body = Enumerator.new do |yielder|
      # Send heartbeat to keep connection alive
      Thread.new do
        loop do
          yielder << ":heartbeat\n\n"
          sleep 30
        end
      rescue IOError
        # Connection closed
      end

      # Subscribe and stream events
      redis.subscribe(channel) do |on|
        on.message do |ch, message|
          yielder << "data: #{message}\n\n"
        end
      end
    rescue IOError
      # Connection closed
    ensure
      redis.quit
    end

    [200, {
      'Content-Type' => 'text/event-stream',
      'Cache-Control' => 'no-cache',
      'X-Accel-Buffering' => 'no' # Disable nginx buffering
    }, body]
  end

  private

  def verify_token(token)
    # Verify JWT/token issued by Otto
    # Return user_id if valid, nil otherwise
    # (Implementation depends on Otto's auth strategy)
  end
end

# config.ru
run SSEHandler.new

# Run with: falcon serve -b 0.0.0.0:9292
```

---

## Appendix B: Further Reading

**Rack Streaming**:
- [Rack 3 Streaming Responses](https://github.com/rack/rack/issues/1600)
- [Rack Hijack API](https://github.com/rack/rack/discussions/2162)
- [Rails SSE with Rack Hijacking](https://blog.chumakoff.com/en/posts/rails_sse_rack_hijacking_api)

**Framework Patterns**:
- [Rails ActionCable Overview](https://guides.rubyonrails.org/action_cable_overview.html)
- [Roda Streaming Plugin](https://github.com/jeremyevans/roda/blob/master/lib/roda/plugins/streaming.rb)
- [Sinatra SSE](https://github.com/radiospiel/sinatra-sse)

**Server-Sent Events**:
- [SSE vs WebSocket Comparison](https://ably.com/blog/websockets-vs-sse)
- [MDN: Using Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events)

**WebSocket Architecture**:
- [WebSocket Best Practices](https://ably.com/topic/websocket-architecture-best-practices)
- [Falcon WebSocket Support](https://socketry.github.io/falcon/)

**Ruby Async Servers**:
- [Falcon](https://github.com/socketry/falcon)
- [Iodine](https://github.com/boazsegev/iodine)
- [AnyCable](https://anycable.io/)
