# spec/support/test_helpers.rb

require 'rack'
require 'rack/test'

# Test helpers for Otto specs
module OttoTestHelpers
  # Unfreeze Otto configuration for testing
  # This allows tests to modify configuration after initialization
  def unfreeze_otto(otto)
    otto.unfreeze_configuration!
    otto
  end

  def create_test_routes_file(filename, routes)
    # Use spec/fixtures directory for test route files
    file_path = File.join('spec', 'fixtures', filename)
    File.write(file_path, routes.join("\n") + "\n")
    file_path
  end

  def create_minimal_otto(routes_content = nil)
    otto = if routes_content
             routes_file = create_test_routes_file('test_routes_minimal.txt', routes_content)
             Otto.new(routes_file)
           else
             Otto.new
           end
    # Unfreeze for testing to allow post-initialization configuration
    otto.unfreeze_configuration!
    otto
  end

  def create_secure_otto(options = {})
    default_options = {
      csrf_protection: true,
      request_validation: true,
      trusted_proxies: ['127.0.0.1', '10.0.0.0/8'],
    }
    routes_file = create_test_routes_file('test_routes_secure.txt', ['GET / TestApp.index'])
    otto = Otto.new(routes_file, default_options.merge(options))
    # Unfreeze for testing to allow post-initialization configuration
    otto.unfreeze_configuration!
    otto
  end

  def mock_rack_env(method: 'GET', path: '/', headers: {}, params: {})
    # Requires rack-test gem for Rack::MockRequest
    env = Rack::MockRequest.env_for(path, method: method, params: params)
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  def extract_security_headers(response)
    return {} unless response.is_a?(Array) && response.length >= 2

    headers = response[1]
    security_headers = {}

    headers.each do |key, value|
      security_headers[key.downcase] = value if key.downcase.match?(/^(x-|strict-transport|content-security|referrer)/i)
    end

    security_headers
  end

  def debug_response(response)
    return unless Otto.debug

    puts "
=== DEBUG RESPONSE ==="
    puts "Status: #{response[0]}"
    puts 'Headers:'
    response[1].each { |k, v| puts "  #{k}: #{v}" }
    puts "Body: #{response[2].respond_to?(:join) ? response[2].join : response[2]}"
    puts "=====================
"
  end

  # Creates a simple test middleware class for specs
  def create_test_middleware
    Class.new do
      def initialize(app, *args)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
