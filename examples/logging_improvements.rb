#!/usr/bin/env ruby
# frozen_string_literal: true

# Example demonstrating Otto's enhanced logging capabilities
# Inspired by structured logging patterns with timing

require_relative '../lib/otto'

# Set up Otto with structured logging
Otto.logger = Logger.new(STDOUT)
Otto.debug = true

# Create a simple Otto app
otto = Otto.new do |routes|
  routes << "GET /example App#handle_request"
  routes << "GET /timed App#timed_operation"
end

# Example handler class demonstrating the new logging patterns
class App
  def self.handle_request(req, res)
    Otto::LoggingHelpers.log_with_metadata(:info, "Request processed",
      user_id: req.params['user_id'],
      cached: false,
      response_size_bytes: 1024
    )

    res.write("Hello World")
    res
  end

  def self.timed_operation(req, res)
    # Example of the log_timed_operation helper
    result = Otto::LoggingHelpers.log_timed_operation(:info, "Template rendered", req.env,
      template: 'example_template',
      layout: 'application',
      partials: ['header', 'footer']
    ) do
      # Simulate some work
      sleep(0.01)
      "Rendered content"
    end

    # Alternative: Manual timing with structured_log
    Otto.structured_log(:debug, "Cache lookup",
      Otto::LoggingHelpers.request_context(req.env).merge(
        cache_key: 'template:example',
        cache_hit: true,
        cache_ttl: 3600
      )
    )

    res.write(result)
    res
  end
end

# Test the logging
puts "\n=== Testing Enhanced Logging ==="
puts "\n1. Standard request (uses log_with_metadata):"
env1 = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/example', 'QUERY_STRING' => 'user_id=123' }
otto.call(env1)

puts "\n2. Timed operation (uses log_timed_operation):"
env2 = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/timed' }
otto.call(env2)

puts "\n=== Expected Output Format ==="
puts "Standard logger format:"
puts "I, [timestamp] INFO -- : Request processed: user_id=123 cached=false response_size_bytes=1024"

puts "\nStructured logging format (if using SemanticLogger or similar):"
puts "I, [timestamp] INFO -- : Template rendered -- {method: \"GET\", path: \"/timed\", ip: \"127.0.0.1\", template: \"example_template\", layout: \"application\", partials: [\"header\", \"footer\"], duration: 10123}"
