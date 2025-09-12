#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'config'

# Simple test runner to demonstrate routes without a server
def test_route(method, path, params = {})
  query_string = params.map { |k, v| "#{k}=#{v}" }.join('&')

  env = {
    'REQUEST_METHOD' => method.to_s.upcase,
    'PATH_INFO' => path,
    'QUERY_STRING' => query_string,
    'rack.input' => StringIO.new(''),
    'HTTP_ACCEPT' => 'application/json',
  }

  status, headers, body = otto.call(env)

  puts "#{method.to_s.upcase} #{path}#{query_string.empty? ? '' : '?' + query_string}"
  puts "Status: #{status}"
  puts "Content-Type: #{headers['content-type'] || headers['Content-Type']}"
  puts "Body: #{body.join}"
  puts "---"
end

puts "Otto Advanced Routes Syntax Test"
puts "================================"

# Test basic routes
test_route(:get, '/')
test_route(:post, '/feedback')

# Test JSON routes
test_route(:get, '/api/users')
test_route(:get, '/api/health')

# Test Logic classes
test_route(:get, '/logic/simple')
test_route(:post, '/logic/process')

# Test namespaced Logic classes
test_route(:get, '/logic/admin')
test_route(:get, '/logic/v2/dashboard')

# Test CSRF exempt routes
test_route(:post, '/api/webhook')
test_route(:put, '/api/external')

# Test custom parameters
test_route(:get, '/config/env')
test_route(:get, '/api/v1')

# Test complex routes
test_route(:post, '/test/everything')

puts "All tests completed!"
