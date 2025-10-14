#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark to measure real-world Otto performance with actual routes and middleware
# Usage: ruby benchmark_middleware_wrap.rb

require 'bundler/setup'
require 'benchmark'
require 'stringio'
require 'tempfile'

require_relative 'lib/otto'

REQUEST_COUNT = 50_000
MIDDLEWARE_COUNT = 40

# Create a temporary routes file
routes_content = <<~ROUTES
  GET / TestApp.index
  GET /users/:id TestApp.show
  POST /users TestApp.create
  GET /health TestApp.health
ROUTES

routes_file = Tempfile.new(['routes', '.txt'])
routes_file.write(routes_content)
routes_file.close

# Define test application
class TestApp
  def self.index(_env, _params = {})
    [200, { 'Content-Type' => 'text/html' }, ['Welcome']]
  end

  def self.show(env, params = {})
    user_id = params[:id] || env.dig('otto.params', :id) || '123'
    [200, { 'Content-Type' => 'text/html' }, ["User #{user_id}"]]
  end

  def self.create(_env, _params = {})
    [201, { 'Content-Type' => 'application/json' }, ['{"id": 123}']]
  end

  def self.health(_env, _params = {})
    [200, { 'Content-Type' => 'text/plain' }, ['OK']]
  end
end

# Create real Rack middleware
class BenchmarkMiddleware
  def initialize(app, _config = nil)
    @app = app
  end

  def call(env)
    @app.call(env)
  end
end

# Create Otto instance with real configuration
otto = Otto.new(routes_file.path)

# Add real Otto security middleware
otto.enable_csrf_protection!
otto.enable_request_validation!

# Add custom middleware to reach target count
current_count = otto.middleware.size
(MIDDLEWARE_COUNT - current_count).times do
  otto.use(Class.new(BenchmarkMiddleware))
end

# Suppress error logging for benchmark
Otto.logger.level = Logger::FATAL

puts "\n" + ("=" * 70)
puts "Otto Performance Benchmark"
puts ("=" * 70)
puts "Configuration:"
puts "  Routes:     #{otto.instance_variable_get(:@route_definitions).size}"
actual_app = otto.instance_variable_get(:@app)
puts "  Middleware: #{otto.middleware.size} (#{MIDDLEWARE_COUNT} total in stack, app built: #{!actual_app.nil?})"
puts "  Requests:   #{REQUEST_COUNT.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
puts ("=" * 70)

# Create realistic Rack environments for different routes
def make_env(method, path)
  {
    'REQUEST_METHOD' => method,
    'PATH_INFO' => path,
    'QUERY_STRING' => '',
    'SERVER_NAME' => 'example.com',
    'SERVER_PORT' => '80',
    'rack.version' => [1, 3],
    'rack.url_scheme' => 'http',
    'rack.input' => StringIO.new,
    'rack.errors' => StringIO.new,
    'rack.multithread' => false,
    'rack.multiprocess' => true,
    'rack.run_once' => false,
    'REMOTE_ADDR' => '192.168.1.100',
    'HTTP_USER_AGENT' => 'Benchmark/1.0',
    'rack.session' => {}
  }
end

# Test different routes
routes = [
  ['GET', '/'],
  ['GET', '/users/123'],
  ['POST', '/users'],
  ['GET', '/health']
]

# Warmup
puts "\nWarming up (1,000 requests)..."
1_000.times do |i|
  method, path = routes[i % routes.size]
  env = make_env(method, path)
  otto.call(env)
end

puts "\n" + ("=" * 70)
puts "Running benchmark..."
puts ("=" * 70)

# Benchmark
result = Benchmark.measure do
  REQUEST_COUNT.times do |i|
    method, path = routes[i % routes.size]
    env = make_env(method, path)
    otto.call(env)
  end
end

total_time = result.real
per_request = (total_time / REQUEST_COUNT * 1_000_000).round(2)
requests_per_sec = (REQUEST_COUNT / total_time).round(0)

puts "\nResults:"
puts ("=" * 70)
puts "  Total time:        #{(total_time * 1000).round(2)}ms"
puts "  Time per request:  #{per_request}µs"
puts "  Requests/sec:      #{requests_per_sec.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
puts ("=" * 70)

# Performance analysis
puts "\nPerformance Analysis:"
if per_request < 20
  puts "  ✓ Excellent performance (< 20µs per request)"
elsif per_request < 50
  puts "  ✓ Good performance (< 50µs per request)"
elsif per_request < 100
  puts "  ~ Acceptable performance (< 100µs per request)"
else
  puts "  ⚠ May need optimization (#{per_request}µs per request)"
end

puts "\nMiddleware overhead: ~#{((per_request - 2.5) / MIDDLEWARE_COUNT).round(3)}µs per middleware"
puts

# Cleanup
routes_file.unlink
