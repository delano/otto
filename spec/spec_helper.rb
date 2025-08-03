# frozen_string_literal: true

require 'bundler/setup'
require 'rack'
require 'rack/test'
require 'json'

# Load Otto
require_relative '../lib/otto'

# Configure Otto for testing
Otto.debug = ENV['OTTO_DEBUG'] == 'true'
Otto.logger.level = Logger::WARN unless Otto.debug

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on Module and main
  config.disable_monkey_patching!

  # Use expect syntax instead of should
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Include Rack::Test helpers
  config.include Rack::Test::Methods

  # Set up clean environment for each test
  config.before(:each) do
    # Reset environment variables
    ENV['RACK_ENV'] = 'test'
    ENV['OTTO_DEBUG'] = 'false' unless ENV['OTTO_DEBUG'] == 'true'
    
    # Clean up any test files in spec/fixtures
    Dir.glob('spec/fixtures/test_routes_*.txt').each { |f| File.delete(f) if File.exist?(f) }
  end

  config.after(:each) do
    # Clean up any test files created during tests in spec/fixtures
    Dir.glob('spec/fixtures/test_routes_*.txt').each { |f| File.delete(f) if File.exist?(f) }
  end

  # Configure output format
  config.color = true
  config.tty = true
  config.formatter = :documentation

  # Random order by default
  config.order = :random
  Kernel.srand config.seed
end

# Test helpers
module OttoTestHelpers
  def create_test_routes_file(filename, routes)
    # Use spec/fixtures directory for test route files
    file_path = File.join('spec', 'fixtures', filename)
    File.write(file_path, routes.join("\n"))
    file_path
  end

  def create_minimal_otto(routes_content = nil)
    if routes_content
      routes_file = create_test_routes_file('test_routes_minimal.txt', routes_content)
      Otto.new(routes_file)
    else
      Otto.new
    end
  end

  def create_secure_otto(options = {})
    default_options = {
      csrf_protection: true,
      request_validation: true,
      trusted_proxies: ['127.0.0.1', '10.0.0.0/8']
    }
    routes_file = create_test_routes_file('test_routes_secure.txt', ['GET / TestApp.index'])
    Otto.new(routes_file, default_options.merge(options))
  end

  def mock_rack_env(method: 'GET', path: '/', headers: {}, params: {})
    env = Rack::MockRequest.env_for(path, method: method, params: params)
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  def extract_security_headers(response)
    return {} unless response.is_a?(Array) && response.length >= 2
    
    headers = response[1]
    security_headers = {}
    
    headers.each do |key, value|
      if key.downcase.match?(/^(x-|strict-transport|content-security|referrer)/i)
        security_headers[key.downcase] = value
      end
    end
    
    security_headers
  end

  def debug_response(response)
    return unless Otto.debug
    
    puts "\n=== DEBUG RESPONSE ==="
    puts "Status: #{response[0]}"
    puts "Headers:"
    response[1].each { |k, v| puts "  #{k}: #{v}" }
    puts "Body: #{response[2].respond_to?(:join) ? response[2].join : response[2]}"
    puts "=====================\n"
  end
end

RSpec.configure do |config|
  config.include OttoTestHelpers
end

# Mock application for testing routes
class TestApp
  def self.index(req, res)
    res.write('Hello World')
  end

  def self.show(req, res)
    res.write("Showing #{req.params['id']}")
  end

  def self.create(req, res)
    res.write('Created')
  end

  def self.update(req, res)
    res.write("Updated #{req.params['id']}")
  end

  def self.destroy(req, res)
    res.write("Deleted #{req.params['id']}")
  end

  def self.error_test(req, res)
    raise StandardError, 'Test error'
  end

  def self.custom_headers(req, res)
    res.headers['X-Custom-Header'] = 'test-value'
    res.write('Custom headers')
  end

  def self.json_response(req, res)
    res.headers['Content-Type'] = 'application/json'
    res.write('{"message": "Hello JSON"}')
  end

  def self.html_response(req, res)
    res.headers['Content-Type'] = 'text/html'
    res.write('<html><head></head><body><h1>Hello HTML</h1></body></html>')
  end
end

class TestInstanceApp
  def initialize(req, res)
    @req = req
    @res = res
  end

  def show
    @res.write("Instance showing #{@req.params['id']}")
  end
end