#!/usr/bin/env ruby

require_relative '../../lib/otto'

class DemoApp
  def self.index(_req, res)
    res.body = <<-HTML
      <h1>Otto MCP Demo</h1>
      <p>MCP endpoint available at: <code>POST /_mcp</code></p>
      <p>Auth tokens: <code>demo-token-123</code>, <code>another-token-456</code></p>

      <h2>Test MCP Initialize</h2>
      <pre>curl -H 'Authorization: Bearer demo-token-123' -H 'Content-Type: application/json' \\
  -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}' \\
  http://localhost:9292/_mcp</pre>

      <h2>List Resources</h2>
      <pre>curl -H 'Authorization: Bearer demo-token-123' -H 'Content-Type: application/json' \\
  -d '{"jsonrpc":"2.0","method":"resources/list","id":2}' \\
  http://localhost:9292/_mcp</pre>

      <h2>List Tools</h2>
      <pre>curl -H 'Authorization: Bearer demo-token-123' -H 'Content-Type: application/json' \\
  -d '{"jsonrpc":"2.0","method":"tools/list","id":3}' \\
  http://localhost:9292/_mcp</pre>
    HTML
  end

  def self.health(_req, res)
    res.body = 'OK'
  end
end

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
  auth_tokens: %w[demo-token-123 another-token-456],
  requests_per_minute: 60,
  tools_per_minute: 20,
                })

run otto
