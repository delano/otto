# examples/mcp_demo/app.rb
require 'json'
require 'time'

# DemoApp provides basic HTML pages for the demo.
class DemoApp
  def self.index(_req, res)
    res.headers['content-type'] = 'text/html; charset=utf-8'
    res.body = <<~HTML
      <h1>Otto MCP Demo</h1>
      <p>This example demonstrates Otto's Model-Controller-Protocol (MCP) feature, which provides a JSON-RPC 2.0 endpoint for interacting with your application.</p>
      <p>The MCP endpoint is available at: <code>POST /_mcp</code></p>
      <p>See the <code>README.md</code> file for detailed `curl` commands to test the API.</p>
    HTML
  end

  def self.health(_req, res)
    res.headers['content-type'] = 'text/plain'
    res.body = 'OK'
  end
end

# UserAPI provides handlers for the MCP tool and resource routes.
class UserAPI
  # MCP Resource: mcp_list_users
  # Accessible via JSON-RPC method "users/list"
  def self.mcp_list_users
    {
      users: [
        { id: 1, name: 'Alice', email: 'alice@example.com' },
        { id: 2, name: 'Bob', email: 'bob@example.com' },
      ],
    }.to_json
  end

  # MCP Tool: mcp_create_user
  # Accessible via JSON-RPC method "create_user"
  def self.mcp_create_user(arguments, _env)
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
