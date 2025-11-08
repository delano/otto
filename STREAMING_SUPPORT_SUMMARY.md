# Otto Streaming Support: Executive Summary

**Investigation Date**: 2025-11-08
**Question**: Should Otto support Server-Sent Events (SSE) and WebSockets?
**Answer**: **No** - Use separate services or long-polling instead

---

## Quick Recommendation

| Use Case | Solution | Complexity | Otto Compatible? |
|----------|----------|------------|------------------|
| **Low-frequency updates (<1/min)** | Long-polling | ⭐ Simple | ✅ Yes |
| **Medium-frequency updates (1-10/sec)** | Separate SSE service | ⭐⭐ Moderate | ✅ Via integration |
| **High-frequency updates (>10/sec)** | Separate WebSocket service | ⭐⭐⭐ Complex | ✅ Via integration |
| **Bidirectional communication** | Separate WebSocket service | ⭐⭐⭐ Complex | ✅ Via integration |

---

## Key Findings

### 1. **Otto's Architecture is Fundamentally Incompatible with Streaming**

Otto is designed as a **stateless, synchronous, request/response** framework:

```
Request → Middleware → Route → Handler → Response → Close Connection
```

SSE/WebSocket require **stateful, long-lived connections**:

```
Request → Upgrade → Keep Open → Stream Data (minutes/hours) → Close
```

**Incompatibilities**:
- ❌ Response handlers expect complete responses (not streaming enumerators)
- ❌ Middleware stack can't unwind during long-lived connections
- ❌ Configuration freezing prevents runtime streaming adjustments
- ❌ Requires async servers (Falcon, Iodine) - breaks server-agnostic design
- ❌ Stateful routing complicates horizontal scaling

### 2. **Industry Best Practice: Separate Services**

Modern frameworks separate real-time communication from REST APIs:

**Rails (ActionCable)**:
```
Rails App (Puma) → Redis Pub/Sub ← ActionCable (Separate Process)
```

**Node.js (Express + Socket.IO)**:
```
Express (HTTP Routes) + Socket.IO (Separate Layer)
```

**Benefits**:
- ✅ Independent scaling (scale WebSocket separately from API)
- ✅ Technology choice (use best tool for each job)
- ✅ Fault isolation (WebSocket crash doesn't affect API)
- ✅ Clear architectural boundaries

### 3. **Long-Polling Works Perfectly with Otto**

For low-to-medium frequency updates, long-polling is **simple and effective**:

```ruby
# Otto route (works with any Rack server)
GET /api/notifications/poll NotificationPollLogic response=json

class NotificationPollLogic < Otto::RequestContext
  def call
    timeout = params[:timeout].to_i.clamp(1, 30)
    last_id = params[:last_id].to_i

    loop do
      notifications = fetch_new(user_id, last_id)
      return { notifications: notifications } if notifications.any?

      break if Time.now - start_time > timeout
      sleep 0.5
    end

    { notifications: [] }
  end
end
```

**Benefits**:
- ✅ HTTP-based (cacheable, proxy-friendly, standard tooling)
- ✅ Works with Otto's synchronous model
- ✅ Compatible with any Rack server (Puma, Unicorn, Passenger)
- ✅ Simple debugging (standard HTTP requests/responses)
- ✅ No external dependencies

---

## Recommended Solutions

### Option 1: Long-Polling (SIMPLEST)

**When to use**:
- Updates less than 1 per minute
- Moderate concurrency (<10,000 clients)
- Simple deployment preferred

**Example**: `/examples/long_polling_example.rb`

**Complexity**: ⭐ Simple
**Otto Integration**: ✅ Native support (no changes needed)

---

### Option 2: Separate SSE Service (RECOMMENDED FOR REAL-TIME)

**When to use**:
- Updates 1-10 per second
- High concurrency (>10,000 clients)
- Near-instant updates required (<100ms latency)

**Architecture**:
```
┌─────────────────┐
│   Otto API      │  ← Stateless HTTP (authentication, business logic)
│   (Puma)        │
└─────────────────┘
         ↓
    ┌─────────┐
    │  Redis  │  ← Message queue (pub/sub)
    │ Pub/Sub │
    └─────────┘
         ↓
┌─────────────────┐
│  SSE Service    │  ← Stateful streaming (Falcon/Iodine)
│  (Falcon)       │
└─────────────────┘
```

**Example**: `/examples/otto_falcon_sse_integration.rb`

**Complexity**: ⭐⭐ Moderate
**Otto Integration**: ✅ Via Redis pub/sub

---

### Option 3: Third-Party Service (COMMERCIAL)

**When to use**:
- Don't want to manage WebSocket infrastructure
- Need global CDN distribution
- Require guaranteed SLA

**Options**:
- **Mercure**: Open-source SSE hub (self-hosted or managed)
- **Ably**: Commercial real-time messaging platform
- **Pusher**: Commercial WebSocket/SSE service

**Complexity**: ⭐⭐ Moderate (integration)
**Otto Integration**: ✅ Via HTTP API

---

## Documentation Created

I've created three comprehensive documents:

### 1. **STREAMING_ARCHITECTURE_ANALYSIS.md** (15,000+ words)
Comprehensive technical analysis covering:
- Otto's current architecture (detailed lifecycle analysis)
- Technical requirements for SSE/WebSocket (Rack 3, hijacking, etc.)
- Industry patterns (Rails, Sinatra, Roda, Go, Node.js)
- Compatibility analysis (why it doesn't fit)
- Best practices and anti-patterns
- Detailed recommendations with code examples

### 2. **examples/otto_falcon_sse_integration.rb** (500+ lines)
Complete working example showing:
- Otto API (authentication, event publishing)
- Falcon SSE service (streaming with Redis pub/sub)
- Production deployment configuration
- Nginx configuration for load balancing
- Client-side JavaScript examples
- Security best practices (JWT tokens, HTTPS)

### 3. **examples/long_polling_example.rb** (600+ lines)
Two complete long-polling examples:
- Notification polling (in-memory)
- Job status polling (Redis-backed)
- Client-side JavaScript (adaptive polling)
- Performance comparison vs SSE/WebSocket

---

## Key Insights

### The Real Question

**Not**: "Can Otto support SSE/WebSocket?"
(Technically possible with massive refactoring)

**But**: "Should Otto support SSE/WebSocket?"
(Architecturally inadvisable)

### Answer: **No**

Otto should remain focused on its core strengths:
- ✅ **Stateless** HTTP APIs
- ✅ **Security-first** design (CSRF, rate limiting, validation)
- ✅ **Privacy by default** (IP masking, geo-location)
- ✅ **Server-agnostic** (works with any Rack server)
- ✅ **Simple** and predictable architecture

Adding SSE/WebSocket would:
- ❌ Compromise architectural integrity
- ❌ Force specific async servers (Falcon, Iodine)
- ❌ Complicate security guarantees (middleware assumptions broken)
- ❌ Add significant complexity for niche use case
- ❌ Go against industry best practices (separation of concerns)

---

## What Otto SHOULD Do

### 1. ✅ Document Integration Patterns

Add official guide: "Integrating Otto with Real-Time Services"
- Long-polling patterns (built-in support)
- Separate SSE service pattern (Otto + Falcon + Redis)
- Third-party service integration (Mercure, Ably, Pusher)

### 2. ✅ Provide Example Code

Add to `examples/` directory:
- `long_polling_example.rb` (already created)
- `otto_falcon_sse_integration.rb` (already created)
- `otto_mercure_integration.rb` (future)

### 3. ⚠️ Consider Plugin System (If Community Demands)

**Only if there's strong demand**, create experimental plugin:
- Clearly marked "experimental" and "unsupported"
- Requires Falcon/Iodine (documented)
- Security implications documented
- No core changes required

### 4. ❌ Do NOT Add to Core

Preserve Otto's architectural integrity by:
- Keeping core stateless and synchronous
- Maintaining server-agnostic design
- Focusing on security and simplicity
- Following industry best practices (separation of concerns)

---

## Migration Guide for Existing Users

If you currently need real-time updates:

### Step 1: Assess Your Use Case

**Low-frequency updates (<1/min)**:
→ Use long-polling (Otto native support)

**Medium-frequency updates (1-10/sec)**:
→ Use separate SSE service (Otto + Falcon + Redis)

**High-frequency or bidirectional**:
→ Use separate WebSocket service or commercial solution

### Step 2: Implementation Path

#### For Long-Polling:
1. Create Otto route with long-polling logic
2. Use `sleep` loop with timeout
3. Client polls with timeout parameter
4. No external dependencies needed

See: `examples/long_polling_example.rb`

#### For Separate SSE Service:
1. Otto API handles authentication and publishes to Redis
2. Separate Falcon app subscribes to Redis and streams SSE
3. Client connects to SSE service with JWT token from Otto
4. Scale Otto and SSE services independently

See: `examples/otto_falcon_sse_integration.rb`

### Step 3: Deployment

**Long-Polling**:
- Deploy with existing Otto setup (Puma, Unicorn, Passenger)
- Increase thread pool size for long-polling routes
- Monitor connection pool (ensure enough threads)

**Separate SSE Service**:
- Deploy Otto API with Puma (standard)
- Deploy Falcon SSE service separately (dedicated servers)
- Use Redis for pub/sub (cluster-ready)
- Configure Nginx with sticky sessions for SSE
- Scale services independently based on load

---

## Performance Guidance

### Long-Polling Capacity

**Example**: Puma with 5 workers × 32 threads = 160 concurrent requests

If long-polling uses 30s timeout:
- 160 concurrent connections
- ~320 clients with 50% utilization
- Up to 10,000 clients with proper thread tuning

**Good for**: Dashboard metrics, low-volume notifications

### SSE/WebSocket Capacity

**Example**: Falcon with 4 workers (async)

Each worker handles thousands of concurrent connections via fibers:
- 10,000+ concurrent SSE connections per server
- Horizontal scaling via Redis pub/sub
- Near-instant message delivery

**Good for**: Chat, multiplayer, high-frequency updates

---

## Conclusion

**Otto should NOT integrate SSE/WebSocket support** because:

1. **Architectural mismatch**: Stateless vs stateful paradigms
2. **Industry consensus**: Separate services is best practice
3. **Complexity cost**: Massive refactoring for niche use case
4. **Better alternatives**: Long-polling (simple) or separate services (powerful)

**Instead, Otto should**:

1. ✅ Document long-polling patterns (works today)
2. ✅ Provide integration examples (Otto + Falcon + Redis)
3. ✅ Recommend third-party solutions (Mercure, Ably, Pusher)
4. ✅ Stay focused on stateless HTTP APIs

**This preserves Otto's core strengths** while enabling users who need real-time functionality to integrate appropriate solutions.

---

## Further Reading

- **Technical Analysis**: `STREAMING_ARCHITECTURE_ANALYSIS.md`
- **SSE Integration Example**: `examples/otto_falcon_sse_integration.rb`
- **Long-Polling Example**: `examples/long_polling_example.rb`
- **Rack 3 Streaming**: https://github.com/rack/rack/issues/1600
- **ActionCable Architecture**: https://guides.rubyonrails.org/action_cable_overview.html
- **SSE vs WebSocket**: https://ably.com/blog/websockets-vs-sse

---

**End of Summary**
