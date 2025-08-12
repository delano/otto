# frozen_string_literal: true

# Test helpers for Otto specs
module OttoTestHelpers
  def create_test_routes_file(filename, routes)
    # Use spec/fixtures directory for test route files
    file_path = File.join('spec', 'fixtures', filename)
    File.write(file_path, routes.join("\n") + "\n")
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
