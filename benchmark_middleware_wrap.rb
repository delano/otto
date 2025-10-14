#!/usr/bin/env ruby
# frozen_string_literal: true

# Throwaway benchmark to measure middleware wrapping performance
# Usage: ruby benchmark_middleware_wrap.rb

require 'bundler/setup'
require 'benchmark'
require 'stringio'

require_relative 'lib/otto'

REQUEST_COUNT = 50_000
MIDDLEWARE_COUNT = 40

# Mock middleware classes
class MockMiddleware1
  def initialize(app, config = nil)
    @app = app
    @config = config
  end

  def call(env)
    @app.call(env)
  end
end

class MockMiddleware2
  def initialize(app, config = nil)
    @app = app
    @config = config
  end

  def call(env)
    @app.call(env)
  end
end

class MockMiddleware3
  def initialize(app, config = nil)
    @app = app
    @config = config
  end

  def call(env)
    @app.call(env)
  end
end

# Base app that just returns success
BASE_APP = lambda do |_env|
  [200, { 'Content-Type' => 'text/plain' }, ['OK']]
end

# Create middleware stack with several middleware
middleware_stack = Otto::Core::MiddlewareStack.new
middleware_stack.add(MockMiddleware1)
middleware_stack.add(MockMiddleware2)
MIDDLEWARE_COUNT.times {
  mw_class = Class.new(MockMiddleware3)
  middleware_stack.add(mw_class)
}

security_config = Otto::Security::Config.new

puts "\nMiddleware Stack (#{middleware_stack.size}):"
middleware_stack.middleware_list.each_with_index do |mw, i|
  print "."
end
puts "\n" + ("=" * 70)

# Create a mock Rack environment
def mock_env
  {
    'REQUEST_METHOD' => 'GET',
    'PATH_INFO' => '/',
    'QUERY_STRING' => '',
    'SERVER_NAME' => 'example.com',
    'SERVER_PORT' => '80',
    'rack.version' => [1, 3],
    'rack.url_scheme' => 'http',
    'rack.input' => StringIO.new,
    'rack.errors' => StringIO.new,
    'rack.multithread' => false,
    'rack.multiprocess' => true,
    'rack.run_once' => false
  }
end

# Warmup
puts "\nWarming up (1,000 requests)..."
1_000.times do
  app = middleware_stack.wrap(BASE_APP, security_config)
  app.call(mock_env)
end

puts "\n" + ("=" * 70)
puts "Running benchmarks (50,000 requests each)...\n\n"

# Benchmark: Current approach (wrap on every request)
puts "CURRENT APPROACH (wrap middleware chain on every request):"
current_result = Benchmark.measure do
  REQUEST_COUNT.times do
    app = middleware_stack.wrap(BASE_APP, security_config)
    app.call(mock_env)
  end
end
puts current_result

# Benchmark: Proposed approach (pre-built app)
puts "\nPROPOSED APPROACH (pre-built middleware chain, reused):"
pre_built_app = middleware_stack.wrap(BASE_APP, security_config)

proposed_result = Benchmark.measure do
  REQUEST_COUNT.times do
    pre_built_app.call(mock_env)
  end
end
puts proposed_result

# Calculate metrics
current_time = current_result.real
proposed_time = proposed_result.real
time_saved = current_time - proposed_time
improvement = ((current_time - proposed_time) / current_time * 100).round(2)
speedup = (current_time / proposed_time).round(2)

puts "\n" + ("=" * 70)
puts "RESULTS SUMMARY:"
puts ("=" * 70)
puts "  Current approach:  #{(current_time * 1000).round(2)}ms total"
puts "                     #{(current_time / REQUEST_COUNT * 1_000_000).round(2)}µs per request"
puts "\n  Proposed approach: #{(proposed_time * 1000).round(2)}ms total"
puts "                     #{(proposed_time / REQUEST_COUNT * 1_000_000).round(2)}µs per request"
puts "\n  Time saved:        #{(time_saved * 1000).round(2)}ms over 50,000 requests"
puts "  Performance gain:  #{improvement}% faster"
puts "  Speedup factor:    #{speedup}x"
puts ("=" * 70)

puts "\nConclusion:"
if improvement > 10
  puts "  ✓ Significant performance improvement - pre-building is worthwhile"
  puts "  ✓ Rebuilding middleware chain on every request is wasteful"
elsif improvement > 5
  puts "  ~ Moderate improvement - worth considering"
else
  puts "  ~ Minimal difference - current approach acceptable"
end
