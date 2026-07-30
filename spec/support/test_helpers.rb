# spec/support/test_helpers.rb
#
# frozen_string_literal: true

require 'rack'
require 'rack/test'
require 'tempfile'

# Test helpers for Otto specs
module OttoTestHelpers
  # Unfreeze Otto configuration for testing
  # This allows tests to modify configuration after initialization
  def unfreeze_otto(otto)
    Otto.unfreeze_for_testing(otto)
  end

  def create_test_routes_file(filename, routes)
    # Create a unique tempfile to avoid shared mutable fixture issues
    # The filename parameter is kept for backwards compatibility but not used
    tempfile = Tempfile.new(['routes', '.txt'])
    tempfile.write(routes.join("\n") + "\n")
    tempfile.rewind
    tempfile.close

    # Store the tempfile in an instance variable to prevent GC during test
    @_test_tempfiles ||= []
    @_test_tempfiles << tempfile

    tempfile.path
  end

  def create_minimal_otto(routes_content = nil)
    otto = if routes_content
             routes_file = create_test_routes_file('test_routes_minimal.txt', routes_content)
             Otto.new(routes_file)
           else
             Otto.new
           end
    # Unfreeze for testing to allow post-initialization configuration
    Otto.unfreeze_for_testing(otto)
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
    Otto.unfreeze_for_testing(otto)
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

  # Walk a chain built by MiddlewareStack#wrap from the OUTSIDE IN, returning
  # each middleware instance in execution order. Stops at the first object that
  # wraps nothing — the base application.
  #
  # Every middleware in the chain must hold its inner app in @app (Otto's own
  # do, as do the spec doubles).
  #
  # @param app [#call] the wrapped application
  # @return [Array<Object>] middleware instances, outermost first
  def middleware_chain(app)
    chain = []
    current = app

    while current.instance_variable_defined?(:@app)
      chain << current
      current = current.instance_variable_get(:@app)
    end

    chain
  end

  # The middleware Otto's outermost IP-privacy pin wraps — i.e. the outermost
  # middleware the application itself registered. Otto pins
  # IPPrivacyMiddleware to the :entrypoint tier (issue #219), so it is always
  # the first link of a chain built from an Otto instance's stack.
  #
  # @param app [#call] the wrapped application
  # @return [Object] the second link of the chain
  def inside_ip_privacy(app)
    expect(app).to be_a(Otto::Security::Middleware::IPPrivacyMiddleware)
    app.instance_variable_get(:@app)
  end
end
