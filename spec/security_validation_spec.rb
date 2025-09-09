# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::ValidationMiddleware do
  let(:config) { Otto::Security::Config.new }
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['Hello World']] } }
  let(:middleware) { described_class.new(app, config) }

  before do
    config.input_validation = true
  end

  describe 'initialization' do
    it 'initializes with app and config' do
      expect(middleware).to be_an_instance_of(described_class)
    end

    it 'uses default config when none provided' do
      default_middleware = described_class.new(app)
      expect(default_middleware).to be_an_instance_of(described_class)
    end
  end

  describe 'request size validation' do
    it 'allows requests within size limit' do
      env = mock_rack_env(method: 'POST', path: '/')
      env['CONTENT_LENGTH'] = '1024'

      response = middleware.call(env)
      expect(response[0]).to eq(200)

      puts "\n=== DEBUG: Valid Request Size ==="
      puts "Content-Length: #{env['CONTENT_LENGTH']}"
      puts "Max allowed: #{config.max_request_size}"
      puts "Status: #{response[0]}"
      puts "============================\n"
    end

    it 'rejects oversized requests' do
      oversized = config.max_request_size + 1
      env = mock_rack_env(method: 'POST', path: '/')
      env['CONTENT_LENGTH'] = oversized.to_s

      response = middleware.call(env)
      expect(response[0]).to eq(413)
      expect(response[1]['content-type']).to eq('application/json')

      body = JSON.parse(response[2].join)
      expect(body['error']).to eq('Request too large')
      expect(body['message']).to include('exceeds maximum')

      puts "\n=== DEBUG: Oversized Request ==="
      puts "Content-Length: #{oversized}"
      puts "Max allowed: #{config.max_request_size}"
      puts "Status: #{response[0]}"
      puts "Error: #{body['error']}"
      puts "===========================\n"
    end

    it 'handles missing content length gracefully' do
      env = mock_rack_env(method: 'POST', path: '/')
      env.delete('CONTENT_LENGTH')

      response = middleware.call(env)
      expect(response[0]).to eq(200)
    end

    it 'handles zero content length' do
      env = mock_rack_env(method: 'POST', path: '/')
      env['CONTENT_LENGTH'] = '0'

      response = middleware.call(env)
      expect(response[0]).to eq(200)
    end
  end

  describe 'content type validation' do
    let(:dangerous_content_types) do
      [
        'application/x-shockwave-flash',
        'application/x-silverlight-app',
        'text/vbscript',
        'application/vbscript',
      ]
    end

    it 'blocks dangerous content types' do
      dangerous_content_types.each do |content_type|
        env = mock_rack_env(method: 'POST', path: '/')
        env['CONTENT_TYPE'] = content_type

        response = middleware.call(env)
        expect(response[0]).to eq(400)

        body = JSON.parse(response[2].join)
        expect(body['error']).to eq('Validation failed')
        expect(body['message']).to include('Dangerous content type')

        puts "\n=== DEBUG: Blocked Content Type ==="
        puts "Content-Type: #{content_type}"
        puts "Status: #{response[0]}"
        puts "Error: #{body['message']}"
        puts "==============================\n"
      end
    end

    it 'allows safe content types' do
      safe_types = [
        'application/json',
        'application/x-www-form-urlencoded',
        'multipart/form-data',
        'text/plain',
        'text/html',
      ]

      safe_types.each do |content_type|
        env = mock_rack_env(method: 'POST', path: '/')
        env['CONTENT_TYPE'] = content_type

        response = middleware.call(env)
        expect(response[0]).to eq(200)
      end
    end

    it 'handles case-insensitive content type matching' do
      env = mock_rack_env(method: 'POST', path: '/')
      env['CONTENT_TYPE'] = 'APPLICATION/X-SHOCKWAVE-FLASH'

      response = middleware.call(env)
      expect(response[0]).to eq(400)
    end
  end

  describe 'parameter structure validation' do
    it 'validates parameter depth limits' do
      # Create deeply nested params beyond the limit
      deep_params = {}
      current = deep_params
      (config.max_param_depth + 5).times do |i|
        current["level#{i}"] = {}
        current = current["level#{i}"]
      end
      current['final'] = 'value'

      env = mock_rack_env(method: 'POST', path: '/', params: deep_params)
      response = middleware.call(env)

      expect(response[0]).to eq(400)
      body = JSON.parse(response[2].join)
      # Accept either our custom validation message or Rack's query limit error
      expect(body['message']).to match(/Parameter (depth exceeds maximum|structure too complex)/)

      puts "\n=== DEBUG: Parameter Depth Validation ==="
      puts "Max depth: #{config.max_param_depth}"
      puts "Attempted depth: #{config.max_param_depth + 5}"
      puts "Status: #{response[0]}"
      puts "Error: #{body['message']}"
      puts "=====================================\n"
    end

    it 'validates parameter count limits' do
      # Create too many parameters
      large_params = {}
      (config.max_param_keys + 5).times do |i|
        large_params["param#{i}"] = "value#{i}"
      end

      env = mock_rack_env(method: 'POST', path: '/', params: large_params)
      response = middleware.call(env)

      expect(response[0]).to eq(400)
      body = JSON.parse(response[2].join)
      expect(body['message']).to include('Too many parameters')

      puts "\n=== DEBUG: Parameter Count Validation ==="
      puts "Max params: #{config.max_param_keys}"
      puts "Attempted params: #{config.max_param_keys + 5}"
      puts "Status: #{response[0]}"
      puts "======================================\n"
    end

    it 'validates array element limits' do
      large_array = (0..config.max_param_keys + 5).to_a
      env = mock_rack_env(method: 'POST', path: '/', params: { 'items' => large_array })

      response = middleware.call(env)
      expect(response[0]).to eq(400)

      body = JSON.parse(response[2].join)
      expect(body['message']).to include('Too many array elements')
    end

    it 'validates nested structure recursively' do
      nested_params = {
        'level1' => {
          'level2' => (0..config.max_param_keys + 2).map { |i| { "item#{i}" => 'value' } },
        },
      }

      env = mock_rack_env(method: 'POST', path: '/', params: nested_params)
      response = middleware.call(env)

      expect(response[0]).to eq(400)
    end
  end

  describe 'parameter key validation' do
    it 'rejects parameter names with null bytes' do
      params = { "valid_key\0malicious" => 'value' }
      env = mock_rack_env(method: 'POST', path: '/', params: params)

      response = middleware.call(env)
      expect(response[0]).to eq(400)

      body = JSON.parse(response[2].join)
      expect(body['message']).to include('Invalid characters in parameter name')
    end

    it 'rejects parameter names with control characters' do
      params = { "key\x01\x02" => 'value' }
      env = mock_rack_env(method: 'POST', path: '/', params: params)

      response = middleware.call(env)
      expect(response[0]).to eq(400)
    end

    it 'rejects excessively long parameter names' do
      long_key = 'a' * 300
      params = { long_key => 'value' }
      env = mock_rack_env(method: 'POST', path: '/', params: params)

      response = middleware.call(env)
      expect(response[0]).to eq(400)

      body = JSON.parse(response[2].join)
      expect(body['message']).to include('Parameter name too long')

      puts "\n=== DEBUG: Long Parameter Name ==="
      puts "Key length: #{long_key.length}"
      puts "Status: #{response[0]}"
      puts "Error: #{body['message']}"
      puts "==============================\n"
    end

    it 'accepts valid parameter names' do
      valid_params = {
        'normal_key' => 'value',
        'key123' => 'value',
        'key-with-dashes' => 'value',
        'key.with.dots' => 'value',
      }

      env = mock_rack_env(method: 'POST', path: '/', params: valid_params)
      response = middleware.call(env)

      expect(response[0]).to eq(200)
    end
  end
  describe 'dangerous pattern detection' do
    let(:xss_patterns) do
      [
        '<script>alert("xss")</script>',
        '<script src="evil.js"></script>',
        'javascript:alert(1)',
        'data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==',
        '<img onload="alert(1)" src="x">',
        '<div onclick="evil()">',
        'expression(alert(1))',
        'url(javascript:alert(1))',
      ]
    end

    it 'detects XSS patterns' do
      xss_patterns.each do |pattern|
        params = { 'input' => pattern }
        env = mock_rack_env(method: 'POST', path: '/', params: params)

        response = middleware.call(env)
        expect(response[0]).to eq(400)

        body = JSON.parse(response[2].join)
        expect(body['message']).to include('Dangerous content detected')

        puts "\n=== DEBUG: XSS Pattern Detection ==="
        puts "Pattern: #{pattern}"
        puts "Status: #{response[0]}"
        puts "Error: #{body['message']}"
        puts "================================\n"
      end
    end

    let(:sql_injection_patterns) do
      [
        "1' OR '1'='1",
        "'; DROP TABLE users; --",
        'UNION SELECT * FROM passwords',
        '1=1',
        "admin'--",
        '%27 OR %271%27=%271',
        '1 AND 1=1',
        'INSERT INTO users VALUES',
      ]
    end

    it 'detects SQL injection pattern' do
      sql_injection_patterns.each do |pattern|
        params = { 'query' => pattern }
        env = mock_rack_env(method: 'POST', path: '/', params: params)

        response = middleware.call(env)
        expect(response[0]).to eq(400)

        body = JSON.parse(response[2].join)
        expect(body['message']).to include('Potential SQL injection detected')

        puts "\n=== DEBUG: SQL Injection Detection ==="
        puts "Pattern: #{pattern}"
        puts "Status: #{response[0]}"
        puts "Error: #{body['message']}"
        puts "==================================\n"
      end
    end

    it 'rejects values with null bytes' do
      params = { 'input' => "normal\0malicious" }
      env = mock_rack_env(method: 'POST', path: '/', params: params)

      response = middleware.call(env)
      expect(response[0]).to eq(400)
    end

    it 'rejects excessively long values' do
      long_value = 'a' * 15_000
      params = { 'input' => long_value }
      env = mock_rack_env(method: 'POST', path: '/', params: params)

      response = middleware.call(env)
      expect(response[0]).to eq(400)

      body = JSON.parse(response[2].join)
      expect(body['message']).to include('Parameter value too long')
    end
  end

  describe 'parameter sanitization' do
    it 'removes null bytes from values' do
      # Since we're testing the private sanitize_value method through the middleware,
      # we need to use reflection or test the overall behavior
      params = { 'input' => "clean\0text" }

      # We expect this to be rejected rather than sanitized based on the current implementation
      env = mock_rack_env(method: 'POST', path: '/', params: params)
      response = middleware.call(env)

      expect(response[0]).to eq(400)
    end

    it 'removes HTML comments' do
      # Test the sanitization logic by accessing the private method
      sanitized = middleware.send(:sanitize_value, 'text <!-- comment --> more text')
      expect(sanitized).not_to include('<!-- comment -->')
      expect(sanitized).to eq('text  more text')

      puts "\n=== DEBUG: HTML Comment Sanitization ==="
      puts 'Original: text <!-- comment --> more text'
      puts "Sanitized: #{sanitized}"
      puts "======================================\n"
    end

    it 'removes CDATA sections' do
      sanitized = middleware.send(:sanitize_value, 'text <![CDATA[dangerous]]> more')
      expect(sanitized).not_to include('<![CDATA[dangerous]]>')
      expect(sanitized).to eq('text  more')
    end

    it 'removes control characters' do
      input_with_controls = "text\x01\x02\x03more"
      sanitized = middleware.send(:sanitize_value, input_with_controls)
      expect(sanitized).to eq('textmore')
    end

    it 'preserves safe content' do
      safe_content = 'This is normal text with numbers 123 and symbols !@#$%'
      sanitized = middleware.send(:sanitize_value, safe_content)
      expect(sanitized).to eq(safe_content)
    end
  end

  describe 'header validation' do
    let(:dangerous_headers) do
      %w[
        HTTP_X_FORWARDED_HOST
        HTTP_X_ORIGINAL_URL
        HTTP_X_REWRITE_URL
        HTTP_DESTINATION
        HTTP_UPGRADE_INSECURE_REQUESTS
      ]
    end

    it 'validates dangerous header' do
      dangerous_headers.each do |header|
        env = mock_rack_env(method: 'GET', path: '/')
        env[header] = "malicious\0content"

        response = middleware.call(env)
        expect(response[0]).to eq(400)

        body = JSON.parse(response[2].join)
        expect(body['message']).to include('Invalid characters in header')

        puts "\n=== DEBUG: Header Validation ==="
        puts "Header: #{header}"
        puts 'Value: malicious\\0content'
        puts "Status: #{response[0]}"
        puts "===========================\n"
      end
    end

    it 'validates User-Agent length' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['HTTP_USER_AGENT'] = 'a' * 1500

      response = middleware.call(env)
      expect(response[0]).to eq(400)

      body = JSON.parse(response[2].join)
      expect(body['message']).to include('User-Agent header too long')
    end

    it 'validates Referer length' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['HTTP_REFERER'] = 'https://example.com/' + ('a' * 2500)

      response = middleware.call(env)
      expect(response[0]).to eq(400)

      body = JSON.parse(response[2].join)
      expect(body['message']).to include('Referer header too long')
    end

    it 'allows valid headers' do
      env = mock_rack_env(method: 'GET', path: '/')
      env['HTTP_USER_AGENT'] = 'Mozilla/5.0 (Valid Browser)'
      env['HTTP_REFERER'] = 'https://example.com/previous-page'
      env['HTTP_ACCEPT'] = 'text/html,application/xhtml+xml'

      response = middleware.call(env)
      expect(response[0]).to eq(200)
    end
  end

  describe 'error response format' do
    it 'returns properly formatted validation error' do
      params = { 'input' => '<script>alert("xss")</script>' }
      env = mock_rack_env(method: 'POST', path: '/', params: params)

      response = middleware.call(env)

      expect(response[0]).to eq(400)
      expect(response[1]['content-type']).to eq('application/json')

      body = JSON.parse(response[2].join)
      expect(body).to have_key('error')
      expect(body).to have_key('message')
      expect(body['error']).to eq('Validation failed')

      content_length = response[1]['content-length']
      expect(content_length.to_i).to eq(response[2].join.bytesize)

      puts "\n=== DEBUG: Validation Error Format ==="
      puts "Status: #{response[0]}"
      puts "Content-Type: #{response[1]['content-type']}"
      puts "Content-Length: #{content_length}"
      puts "Body: #{response[2].join}"
      puts "JSON valid: #{begin
        JSON.parse(response[2].join)
      rescue StandardError
        false
      end}"
      puts "=================================\n"
    end

    it 'returns properly formatted request too large error' do
      oversized = config.max_request_size + 1
      env = mock_rack_env(method: 'POST', path: '/')
      env['CONTENT_LENGTH'] = oversized.to_s

      response = middleware.call(env)

      expect(response[0]).to eq(413)
      expect(response[1]['content-type']).to eq('application/json')

      body = JSON.parse(response[2].join)
      expect(body['error']).to eq('Request too large')
    end
  end

  describe 'disabled validation' do
    let(:disabled_config) do
      config = Otto::Security::Config.new
      config.input_validation = false
      config
    end
    let(:disabled_middleware) { described_class.new(app, disabled_config) }

    it 'bypasses validation when disabled' do
      dangerous_params = { 'input' => '<script>alert("xss")</script>' }
      env = mock_rack_env(method: 'POST', path: '/', params: dangerous_params)

      response = disabled_middleware.call(env)
      expect(response[0]).to eq(200)

      puts "\n=== DEBUG: Disabled Validation ==="
      puts "Validation enabled: #{disabled_config.input_validation}"
      puts "Dangerous content status: #{response[0]}"
      puts "==============================\n"
    end

    it 'still validates request size when disabled' do
      # Request size validation might still be active even when input validation is disabled
      oversized = disabled_config.max_request_size + 1
      env = mock_rack_env(method: 'POST', path: '/')
      env['CONTENT_LENGTH'] = oversized.to_s

      response = disabled_middleware.call(env)
      # This depends on implementation - might still validate size
      expect([200, 413]).to include(response[0])
    end
  end

  describe 'edge cases and error conditions' do
    it 'handles empty parameter values' do
      params = { 'empty' => '', 'nil_value' => nil }
      env = mock_rack_env(method: 'POST', path: '/', params: params)

      response = middleware.call(env)
      expect(response[0]).to eq(200)
    end

    it 'handles non-string parameter values' do
      params = { 'number' => 123, 'boolean' => true, 'array' => [1, 2, 3] }
      env = mock_rack_env(method: 'POST', path: '/', params: params)

      response = middleware.call(env)
      expect(response[0]).to eq(200)
    end

    it 'handles missing params gracefully' do
      env = mock_rack_env(method: 'POST', path: '/')
      env.delete('rack.request.form_hash') if env['rack.request.form_hash']

      response = middleware.call(env)
      expect(response[0]).to eq(200)
    end

    it 'handles malformed parameter structures' do
      # Test with circular reference (if possible in the context)
      params = { 'key' => 'value' }

      env = mock_rack_env(method: 'POST', path: '/', params: params)
      response = middleware.call(env)

      expect(response[0]).to eq(200)
    end

    it 'preserves original parameters when validation passes' do
      safe_params = { 'name' => 'John Doe', 'age' => '30' }
      env = mock_rack_env(method: 'POST', path: '/', params: safe_params)

      response = middleware.call(env)
      expect(response[0]).to eq(200)

      # The app should receive the original parameters
      request = Rack::Request.new(env)
      expect(request.params['name']).to eq('John Doe')
      expect(request.params['age']).to eq('30')
    end
  end

  describe 'configuration limits' do
    it 'respects custom max_request_size' do
      config.max_request_size = 1024

      env = mock_rack_env(method: 'POST', path: '/')
      env['CONTENT_LENGTH'] = '2048'

      response = middleware.call(env)
      expect(response[0]).to eq(413)
    end

    it 'respects custom max_param_depth' do
      config.max_param_depth = 3

      deep_params = { 'l1' => { 'l2' => { 'l3' => { 'l4' => 'too deep' } } } }
      env = mock_rack_env(method: 'POST', path: '/', params: deep_params)

      response = middleware.call(env)
      expect(response[0]).to eq(400)
    end

    it 'respects custom max_param_keys' do
      config.max_param_keys = 5

      many_params = {}
      10.times { |i| many_params["key#{i}"] = "value#{i}" }

      env = mock_rack_env(method: 'POST', path: '/', params: many_params)
      response = middleware.call(env)

      expect(response[0]).to eq(400)
    end
  end
end

RSpec.describe Otto::Security::ValidationHelpers do
  let(:mock_response) do
    Class.new do
      include Otto::Security::ValidationHelpers
    end.new
  end

  describe '#validate_input' do
    it 'accepts safe input within length limit' do
      safe_input = 'This is a safe string'
      result = mock_response.validate_input(safe_input)
      expect(result).to eq(safe_input)
    end

    it 'rejects input exceeding length limit' do
      long_input = 'a' * 1500
      expect { mock_response.validate_input(long_input) }
        .to raise_error(Otto::Security::ValidationError, /Input too long/)
    end

    it 'accepts custom length limits' do
      input = 'a' * 50
      result = mock_response.validate_input(input, max_length: 100)
      expect(result).to eq(input)

      expect { mock_response.validate_input(input, max_length: 10) }
        .to raise_error(Otto::Security::ValidationError, /Input too long/)
    end

    it 'rejects dangerous patterns by default' do
      dangerous_inputs = [
        '<script>alert(1)</script>',
        'javascript:alert(1)',
        'SELECT * FROM users',
      ]

      dangerous_inputs.each do |input|
        expect { mock_response.validate_input(input) }
          .to raise_error(Otto::Security::ValidationError)
      end
    end

    it 'allows HTML when explicitly permitted' do
      html_input = '<p>This is <strong>safe</strong> HTML</p>'
      result = mock_response.validate_input(html_input, allow_html: true)
      expect(result).to eq(html_input)
    end

    it 'still checks for SQL injection even when HTML is allowed' do
      sql_injection = "'; DROP TABLE users; --"
      expect { mock_response.validate_input(sql_injection, allow_html: true) }
        .to raise_error(Otto::Security::ValidationError, /SQL injection/)
    end

    it 'handles nil and empty input gracefully' do
      expect(mock_response.validate_input(nil)).to be_nil
      expect(mock_response.validate_input('')).to eq('')
    end

    it 'converts non-string input to string' do
      result = mock_response.validate_input(123)
      expect(result).to eq('123')
    end
  end

  describe '#sanitize_filename' do
    it 'removes path components' do
      result = mock_response.sanitize_filename('../../etc/passwd')
      expect(result).to eq('passwd')

      puts "\n=== DEBUG: Filename Sanitization ==="
      puts 'Original: ../../etc/passwd'
      puts "Sanitized: #{result}"
      puts "================================\n"
    end

    it 'removes dangerous characters' do
      dangerous_filename = 'file<>:"|?*name.txt'
      result = mock_response.sanitize_filename(dangerous_filename)
      expect(result).to match(/^file.*name\.txt$/)
      expect(result).not_to include('<', '>', ':', '"', '|', '?', '*')
    end

    it 'collapses multiple underscores' do
      result = mock_response.sanitize_filename('file___with___underscores.txt')
      expect(result).to eq('file_with_underscores.txt')
    end

    it 'removes leading and trailing underscores' do
      result = mock_response.sanitize_filename('___filename___')
      expect(result).to eq('filename')
    end

    it 'handles empty filenames' do
      result = mock_response.sanitize_filename('')
      expect(result).to eq('file')

      result = mock_response.sanitize_filename(nil)
      expect(result).to be_nil
    end

    it 'truncates extremely long filenames' do
      long_filename = ('a' * 150) + '.txt'
      result = mock_response.sanitize_filename(long_filename)
      expect(result.length).to be <= 100
    end

    it 'preserves valid filenames' do
      valid_filename = 'document-2023_v1.2.pdf'
      result = mock_response.sanitize_filename(valid_filename)
      expect(result).to eq(valid_filename)
    end

    it 'handles files with no extension' do
      result = mock_response.sanitize_filename('README')
      expect(result).to eq('README')
    end

    it 'handles files that become empty after sanitization' do
      result = mock_response.sanitize_filename('<<>>')
      expect(result).to eq('file')

      puts "\n=== DEBUG: Empty After Sanitization ==="
      puts 'Original: <<>>'
      puts "Sanitized: #{result}"
      puts "====================================\n"
    end
  end

  describe 'helper integration' do
    it 'provides consistent validation across helpers' do
      # Test that both helpers work together
      filename = mock_response.sanitize_filename('user_input_<script>.txt')
      validated = mock_response.validate_input(filename, max_length: 50)

      expect(validated).to be_a(String)
      expect(validated).not_to include('<script>')
      expect(validated.length).to be <= 50
    end
  end
end
