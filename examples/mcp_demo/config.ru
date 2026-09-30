# examples/mcp_demo/config.ru

require_relative '../../lib/otto'
require_relative 'app'

# Rack::Attack counts requests in a cache store and raises
# Rack::Attack::MissingStoreError without one. Outside Rails there is no
# default store, so this demo keeps the counts in process memory. Use a shared
# store (for example Redis) when the app runs in more than one process.
class DemoRateLimitStore
  def initialize
    @entries = {}
    @mutex   = Mutex.new
  end

  def read(key)
    @mutex.synchronize { live_value(key) }
  end

  def write(key, value, expires_in: nil)
    @mutex.synchronize { @entries[key] = [value, expires_in && (now + expires_in)] }
    value
  end

  # Returns nil for a missing key, as ActiveSupport cache stores do; Rack::Attack
  # then writes the first count itself.
  def increment(key, amount = 1, **)
    @mutex.synchronize do
      value = live_value(key)
      value && (@entries[key][0] = value + amount)
    end
  end

  def delete(key)
    @mutex.synchronize { @entries.delete(key) }
  end

  private

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def live_value(key)
    value, expires_at = @entries[key]
    return value unless expires_at && expires_at <= now

    @entries.delete(key)
    nil
  end
end

# Initialize Otto with MCP support. MCP must be enabled when the routes file
# loads, or Otto skips its MCP and TOOL lines.
app = Otto.new('routes', {
  mcp_enabled: true,
  auth_tokens: ['demo-token-123', 'another-token-456'],
  requests_per_minute: 60, # Rate limiting for the MCP endpoint
  tools_per_minute: 20,
})

# The `mcp_enabled: true` flag sets up the /_mcp endpoint. The routes file
# declares one MCP resource and one tool for it to serve.

Rack::Attack.cache.store = DemoRateLimitStore.new
use Rack::Attack
run app
