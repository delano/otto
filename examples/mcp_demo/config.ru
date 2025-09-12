# examples/mcp_demo/config.ru

require_relative '../../lib/otto'
require_relative 'app'

# Initialize Otto with MCP support
app = Otto.new('routes', {
  mcp_enabled: true,
  auth_tokens: ['demo-token-123', 'another-token-456'],
  requests_per_minute: 60, # Rate limiting for the MCP endpoint
  tools_per_minute: 20,
})

# The `mcp_enabled: true` flag automatically sets up the /_mcp endpoint.
# The routes file maps MCP and TOOL methods to classes.

run app
