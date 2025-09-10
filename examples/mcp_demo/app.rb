# examples/mcp_demo/app.rb

# Example Otto application with MCP support
# This demonstrates Phase 1 & 2 implementation

require_relative '../../lib/otto'

class UserAPI
  def self.mcp_list_users
    {
      users: [
        { id: 1, name: 'Alice', email: 'alice@example.com' },
        { id: 2, name: 'Bob', email: 'bob@example.com' },
      ],
    }.to_json
  end

  def self.mcp_create_user(arguments, _env)
    # Tool handler that creates a user
    name = arguments['name'] || 'Anonymous'
    email = arguments['email'] || "#{name.downcase}@example.com"

    new_user = {
      id: rand(1000..9999),
      name: name,
      email: email,
      created_at: Time.now.iso8601,
    }

    "Created user: #{new_user.to_json}"
  end
end

# Initialize Otto with MCP support
otto = Otto.new('routes', {
                  mcp_enabled: true,
  auth_tokens: ['demo-token-123'],  # Simple token auth
  requests_per_minute: 10,          # Lower for demo
  tools_per_minute: 5,
                })

# Enable MCP with authentication tokens
otto.enable_mcp!({
                   auth_tokens: %w[demo-token-123 another-token-456],
  enable_validation: true,
  enable_rate_limiting: true,
                 })

puts 'Otto MCP Demo Server starting...'
puts 'MCP endpoint: POST /_mcp'
puts 'Auth tokens: demo-token-123, another-token-456'
puts "Usage: curl -H 'Authorization: Bearer demo-token-123' -H 'Content-Type: application/json' \\"
puts "       -d '{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1,\"params\":{}}' \\"
puts '       http://localhost:9292/_mcp'

otto
