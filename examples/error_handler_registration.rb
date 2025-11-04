#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Error Handler Registration
#
# This example demonstrates how to register custom error handlers for expected
# business logic errors, preventing them from being logged as unhandled 500 errors.

require_relative '../lib/otto'

# Define some business logic error classes
module MyApp
  class MissingResourceError < StandardError; end
  class ExpiredResourceError < StandardError; end

  class RateLimitError < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after: 60)
      super(message)
      @retry_after = retry_after
    end
  end
end

# Create routes file
routes_content = <<~ROUTES
  GET /resource/:id  ResourceHandler.show
  POST /action       ActionHandler.process
ROUTES

File.write('/tmp/otto_error_routes.txt', routes_content)

# Define handlers that might raise expected errors
class ResourceHandler
  def self.show(req, res)
    resource_id = req.params[:id]

    # Simulate resource lookup
    raise MyApp::MissingResourceError, "Resource #{resource_id} not found" if resource_id == 'missing'
    raise MyApp::ExpiredResourceError, "Resource #{resource_id} expired" if resource_id == 'expired'

    res.status = 200
    res.headers['Content-Type'] = 'application/json'
    res.write(JSON.generate({ id: resource_id, name: "Resource #{resource_id}" }))
  end
end

class ActionHandler
  def self.process(req, res)
    # Simulate rate limiting
    raise MyApp::RateLimitError.new('Too many requests', retry_after: 120)
  end
end

# Create Otto app
otto = Otto.new('/tmp/otto_error_routes.txt')

# Register error handlers BEFORE first request
puts "Registering error handlers..."

# Basic registration with status code and log level
otto.register_error_handler(MyApp::MissingResourceError, status: 404, log_level: :info)
otto.register_error_handler(MyApp::ExpiredResourceError, status: 410, log_level: :info)

# Advanced registration with custom response handler
otto.register_error_handler(MyApp::RateLimitError, status: 429, log_level: :warn) do |error, req|
  {
    error: 'RateLimited',
    message: error.message,
    retry_after: error.retry_after,
    path: req.path
  }
end

puts "\n=== Test 1: Missing Resource (404) ==="
env = {
  'REQUEST_METHOD' => 'GET',
  'PATH_INFO' => '/resource/missing',
  'HTTP_ACCEPT' => 'application/json',
  'REMOTE_ADDR' => '127.0.0.1'
}

status, headers, body = otto.call(env)
puts "Status: #{status}"
puts "Body: #{body.first}"
puts "Log level: INFO (not ERROR)"

puts "\n=== Test 2: Expired Resource (410) ==="
env['PATH_INFO'] = '/resource/expired'

status, headers, body = otto.call(env)
puts "Status: #{status}"
puts "Body: #{body.first}"
puts "Log level: INFO (not ERROR)"

puts "\n=== Test 3: Rate Limited (429) with custom handler ==="
env = {
  'REQUEST_METHOD' => 'POST',
  'PATH_INFO' => '/action',
  'HTTP_ACCEPT' => 'application/json',
  'REMOTE_ADDR' => '127.0.0.1'
}

status, headers, body = otto.call(env)
puts "Status: #{status}"
puts "Body: #{body.first}"
puts "Log level: WARN (not ERROR)"
puts "Custom fields: retry_after included"

puts "\n=== Test 4: Successful Request ==="
env = {
  'REQUEST_METHOD' => 'GET',
  'PATH_INFO' => '/resource/123',
  'HTTP_ACCEPT' => 'application/json',
  'REMOTE_ADDR' => '127.0.0.1'
}

status, headers, body = otto.call(env)
puts "Status: #{status}"
puts "Body: #{body.first}"

puts "\n=== Benefits ==="
puts "✓ Expected errors return proper HTTP status codes (not 500)"
puts "✓ Logged at INFO/WARN level (not ERROR)"
puts "✓ No backtrace spam for expected conditions"
puts "✓ Still generates error IDs for correlation"
puts "✓ Custom response handlers for complex error data"
puts "✓ Content negotiation (JSON/plain text) automatic"

# Cleanup
File.delete('/tmp/otto_error_routes.txt') if File.exist?('/tmp/otto_error_routes.txt')
