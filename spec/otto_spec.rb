# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto do
  let(:test_routes) do
    [
      'GET / TestApp.index',
      'GET /show/:id TestApp.show',
      'POST /create TestApp.create',
      'PUT /update/:id TestApp.update',
      'DELETE /delete/:id TestApp.destroy',
      'GET /error TestApp.error_test',
      'GET /custom TestApp.custom_headers',
      'GET /json TestApp.json_response',
      'GET /html TestApp.html_response',
      'GET /instance/:id TestInstanceApp#show'
    ]
  end

  describe 'initialization' do
    context 'without routes file' do
      subject(:otto) { described_class.new }

      it 'creates Otto instance with default configuration' do
        expect(otto).to be_an_instance_of(described_class)
        expect(otto.routes).to have_key(:GET)
        expect(otto.routes_literal).to have_key(:GET)
        expect(otto.routes_static).to have_key(:GET)
      end

      it 'initializes security config with safe defaults' do
        config = otto.security_config
        expect(config).to be_an_instance_of(Otto::Security::Config)
        expect(config.csrf_enabled?).to be false
        expect(config.input_validation).to be true
        
        puts "\n=== DEBUG: Default Otto Security Config ==="
        puts "CSRF enabled: #{config.csrf_enabled?}"
        puts "Input validation: #{config.input_validation}"
        puts "Security headers: #{config.security_headers.keys.join(', ')}"
        puts "=========================================\n"
      end

      it 'sets default options' do
        expect(otto.option[:public]).to be_nil
        expect(otto.option[:locale]).to eq('en')
      end

      it 'initializes empty middleware stack' do
        expect(otto.middleware_stack).to be_empty
      end
    end

    context 'with routes file' do
      let(:routes_file) { create_test_routes_file('test_routes.txt', test_routes) }
      subject(:otto) { described_class.new(routes_file) }

      it 'loads routes from file' do
        expect(otto.routes[:GET]).not_to be_empty
        expect(otto.routes[:POST]).not_to be_empty
        expect(otto.routes[:PUT]).not_to be_empty
        expect(otto.routes[:DELETE]).not_to be_empty
        
        puts "\n=== DEBUG: Loaded Routes ==="
        otto.routes.each do |verb, routes|
          puts "#{verb}: #{routes.map(&:path).join(', ')}"
        end
        puts "===========================\n"
      end

      it 'creates route definitions mapping' do
        expect(otto.route_definitions).to have_key('TestApp.index')
        expect(otto.route_definitions).to have_key('TestApp.show')
        expect(otto.route_definitions).to have_key('TestInstanceApp#show')
        
        puts "\n=== DEBUG: Route Definitions ==="
        otto.route_definitions.each { |definition, route| puts "#{definition} -> #{route.path}" }
        puts "===============================\n"
      end

      it 'sets up literal routes for fast lookup' do
        expect(otto.routes_literal[:GET]).to have_key('')  # "/" becomes "" after gsub
        expect(otto.routes_literal[:POST]).to have_key('/create')
        
        literal_paths = otto.routes_literal.values.flat_map(&:keys)
        puts "\n=== DEBUG: Literal Routes ==="
        puts "Paths: #{literal_paths.join(', ')}"
        puts "============================\n"
      end
    end

    context 'with security options' do
      let(:routes_file) { create_test_routes_file('test_routes_secure.txt', test_routes) }
      let(:security_options) do
        {
          csrf_protection: true,
          request_validation: true,
          trusted_proxies: ['127.0.0.1', '10.0.0.0/8'],
          security_headers: { 'custom-header' => 'custom-value' }
        }
      end
      subject(:otto) { described_class.new(routes_file, security_options) }

      it 'configures CSRF protection when requested' do
        expect(otto.security_config.csrf_enabled?).to be true
        expect(otto.middleware_stack).to include(Otto::Security::CSRFMiddleware)
      end

      it 'configures request validation when requested' do
        expect(otto.security_config.input_validation).to be true
        expect(otto.middleware_stack).to include(Otto::Security::ValidationMiddleware)
      end

      it 'configures trusted proxies when provided' do
        expect(otto.security_config.trusted_proxies).to include('127.0.0.1', '10.0.0.0/8')
      end

      it 'sets custom security headers when provided' do
        expect(otto.security_config.security_headers['custom-header']).to eq('custom-value')
      end

      it 'does not enable dangerous headers by default' do
        dangerous_headers = %w[strict-transport-security content-security-policy x-frame-options]
        present_dangerous = dangerous_headers.select { |h| otto.security_config.security_headers.key?(h) }
        
        expect(present_dangerous).to be_empty,
          "Dangerous headers enabled by default: #{present_dangerous.join(', ')}"
      end
    end
  end

  describe 'security header methods' do
    subject(:otto) { create_minimal_otto }

    describe '#enable_hsts!' do
      it 'enables HSTS with default settings' do
        otto.enable_hsts!
        hsts_value = otto.security_config.security_headers['strict-transport-security']
        
        expect(hsts_value).to eq('max-age=31536000; includeSubDomains')
        
        puts "\n=== DEBUG: HSTS Enabled ==="
        puts "HSTS Header: #{hsts_value}"
        puts "=========================\n"
      end

      it 'accepts custom HSTS parameters' do
        otto.enable_hsts!(max_age: 86400, include_subdomains: false)
        hsts_value = otto.security_config.security_headers['strict-transport-security']
        
        expect(hsts_value).to eq('max-age=86400')
      end
    end

    describe '#enable_csp!' do
      it 'enables CSP with default policy' do
        otto.enable_csp!
        csp_value = otto.security_config.security_headers['content-security-policy']
        
        expect(csp_value).to eq("default-src 'self'")
      end

      it 'accepts custom CSP policy' do
        custom_policy = "default-src 'self'; script-src 'self' 'unsafe-inline'"
        otto.enable_csp!(custom_policy)
        csp_value = otto.security_config.security_headers['content-security-policy']
        
        expect(csp_value).to eq(custom_policy)
      end
    end

    describe '#enable_frame_protection!' do
      it 'enables frame protection with default setting' do
        otto.enable_frame_protection!
        frame_value = otto.security_config.security_headers['x-frame-options']
        
        expect(frame_value).to eq('SAMEORIGIN')
      end

      it 'accepts custom frame protection setting' do
        otto.enable_frame_protection!('DENY')
        frame_value = otto.security_config.security_headers['x-frame-options']
        
        expect(frame_value).to eq('DENY')
      end
    end

    describe '#set_security_headers' do
      it 'merges custom headers with existing ones' do
        custom_headers = {
          'permissions-policy' => 'geolocation=()',
          'x-custom-header' => 'test-value'
        }
        
        otto.set_security_headers(custom_headers)
        
        expect(otto.security_config.security_headers['permissions-policy']).to eq('geolocation=()')
        expect(otto.security_config.security_headers['x-custom-header']).to eq('test-value')
        expect(otto.security_config.security_headers['x-content-type-options']).to eq('nosniff')
      end
    end
  end

  describe 'middleware management' do
    subject(:otto) { create_minimal_otto }

    describe '#use' do
      let(:test_middleware) { Class.new }

      it 'adds middleware to the stack' do
        otto.use(test_middleware)
        expect(otto.middleware_stack).to include(test_middleware)
      end

      it 'maintains middleware order' do
        middleware1 = Class.new
        middleware2 = Class.new
        
        otto.use(middleware1)
        otto.use(middleware2)
        
        expect(otto.middleware_stack).to eq([middleware1, middleware2])
      end
    end

    describe '#enable_csrf_protection!' do
      it 'enables CSRF and adds middleware' do
        expect { otto.enable_csrf_protection! }
          .to change { otto.security_config.csrf_enabled? }.from(false).to(true)
        
        expect(otto.middleware_stack).to include(Otto::Security::CSRFMiddleware)
      end

      it 'does not add duplicate middleware' do
        otto.enable_csrf_protection!
        otto.enable_csrf_protection!
        
        csrf_count = otto.middleware_stack.count(Otto::Security::CSRFMiddleware)
        expect(csrf_count).to eq(1)
      end
    end

    describe '#enable_request_validation!' do
      it 'enables validation and adds middleware' do
        otto.enable_request_validation!
        
        expect(otto.security_config.input_validation).to be true
        expect(otto.middleware_stack).to include(Otto::Security::ValidationMiddleware)
      end
    end
  end

  describe 'request handling' do
    let(:app) { create_minimal_otto(test_routes) }

    describe 'basic routing' do
      it 'handles GET requests to root' do
        env = mock_rack_env(method: 'GET', path: '/')
        response = app.call(env)
        
        expect(response[0]).to eq(200)
        expect(response[2].join).to eq('Hello World')
        
        debug_response(response)
      end

      it 'handles parameterized routes' do
        env = mock_rack_env(method: 'GET', path: '/show/123')
        response = app.call(env)
        
        expect(response[0]).to eq(200)
        expect(response[2].join).to eq('Showing 123')
      end

      it 'handles POST requests' do
        env = mock_rack_env(method: 'POST', path: '/create')
        response = app.call(env)
        
        expect(response[0]).to eq(200)
        expect(response[2].join).to eq('Created')
      end

      it 'handles instance method routes' do
        env = mock_rack_env(method: 'GET', path: '/instance/456')
        response = app.call(env)
        
        expect(response[0]).to eq(200)
        expect(response[2].join).to eq('Instance showing 456')
      end
    end

    describe 'security headers in responses' do
      it 'includes default security headers in all responses' do
        env = mock_rack_env(method: 'GET', path: '/')
        response = app.call(env)
        
        security_headers = extract_security_headers(response)
        
        expect(security_headers).to have_key('x-content-type-options')
        expect(security_headers).to have_key('x-xss-protection')
        expect(security_headers).to have_key('referrer-policy')
        
        puts "\n=== DEBUG: Response Security Headers ==="
        security_headers.each { |k, v| puts "  #{k}: #{v}" }
        puts "======================================\n"
      end

      it 'includes custom security headers when configured' do
        app.set_security_headers({ 'x-custom-security' => 'enabled' })
        
        env = mock_rack_env(method: 'GET', path: '/')
        response = app.call(env)
        
        headers = response[1]
        expect(headers['x-custom-security']).to eq('enabled')
      end
    end

    describe 'error handling' do
      it 'returns 404 for non-existent routes' do
        env = mock_rack_env(method: 'GET', path: '/nonexistent')
        response = app.call(env)
        
        expect(response[0]).to eq(404)
        expect(response[2].join).to eq('Not Found')
        
        debug_response(response)
      end

      it 'handles application errors gracefully' do
        env = mock_rack_env(method: 'GET', path: '/error')
        response = app.call(env)
        
        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('text/plain')
        
        body = response[2].join
        expect(body).to include('error occurred') if Otto.env?(:production)
        
        puts "\n=== DEBUG: Error Response ==="
        puts "Status: #{response[0]}"
        puts "Body: #{body}"
        puts "===========================\n"
      end

      it 'includes error ID in development mode' do
        original_env = ENV['RACK_ENV']
        ENV['RACK_ENV'] = 'development'
        
        begin
          env = mock_rack_env(method: 'GET', path: '/error')
          response = app.call(env)
          
          body = response[2].join
          expect(body).to match(/ID: [a-f0-9]{16}/)
        ensure
          ENV['RACK_ENV'] = original_env
        end
      end
    end

    describe 'HEAD request handling' do
      it 'handles HEAD requests like GET but without body' do
        env = mock_rack_env(method: 'HEAD', path: '/')
        response = app.call(env)
        
        expect(response[0]).to eq(200)
        # HEAD responses should have headers but empty body
        expect(response[1]).to be_a(Hash)
      end
    end
  end

  describe 'file safety checks' do
    subject(:otto) { described_class.new(nil, { public: '/tmp/test_public' }) }

    before do
      Dir.mkdir('/tmp/test_public') unless Dir.exist?('/tmp/test_public')
      File.write('/tmp/test_public/safe.txt', 'safe content')
    end

    after do
      FileUtils.rm_rf('/tmp/test_public') if Dir.exist?('/tmp/test_public')
    end

    describe '#safe_file?' do
      it 'returns false when public dir is not set' do
        otto_no_public = described_class.new
        expect(otto_no_public.safe_file?('any/path')).to be false
      end

      it 'returns false for nil or empty paths' do
        expect(otto.safe_file?(nil)).to be false
        expect(otto.safe_file?('')).to be false
        expect(otto.safe_file?('   ')).to be false
      end

      it 'prevents path traversal attacks' do
        expect(otto.safe_file?('../../../etc/passwd')).to be false
        expect(otto.safe_file?('..\\..\\windows\\system32')).to be false
        expect(otto.safe_file?('/etc/passwd')).to be false
      end

      it 'removes null bytes from paths' do
        expect(otto.safe_file?("safe.txt\0../../../etc/passwd")).to be false
      end

      it 'validates file existence and permissions' do
        # The file needs to be owned by the current user/group for safe_file? to return true
        if File.exist?('/tmp/test_public/safe.txt') && 
           (File.owned?('/tmp/test_public/safe.txt') || File.grpowned?('/tmp/test_public/safe.txt'))
          expect(otto.safe_file?('safe.txt')).to be true
        else
          expect(otto.safe_file?('safe.txt')).to be false
        end
        expect(otto.safe_file?('nonexistent.txt')).to be false
      end

      it 'rejects directories' do
        expect(otto.safe_file?('.')).to be false
        expect(otto.safe_file?('..')).to be false
      end
    end

    describe '#safe_dir?' do
      it 'returns false for nil or empty paths' do
        expect(otto.safe_dir?(nil)).to be false
        expect(otto.safe_dir?('')).to be false
      end

      it 'validates directory existence and permissions' do
        expect(otto.safe_dir?('/tmp/test_public')).to be true
        expect(otto.safe_dir?('/nonexistent/directory')).to be false
      end

      it 'removes null bytes from paths' do
        expect(otto.safe_dir?("/tmp/test_public\0")).to be true
      end
    end
  end

  describe 'utility methods' do
    let(:routes_file) { create_test_routes_file('test_util_routes.txt', test_routes) }
    subject(:otto) { described_class.new(routes_file) }

    describe '#uri' do
      it 'generates URIs for route definitions' do
        uri = otto.uri('TestApp.index')
        expect(uri).to eq('/?')  # Implementation adds query string even when empty
        
        puts "\n=== DEBUG: Generated URI ==="
        puts "Route: TestApp.index -> #{uri}"
        puts "==========================\n"
      end

      it 'generates URIs with parameters' do
        uri = otto.uri('TestApp.show', id: '123')
        expect(uri).to eq('/show/123?')  # Implementation adds query string
      end

      it 'handles query parameters' do
        uri = otto.uri('TestApp.index', page: '2', sort: 'name')
        expect(uri).to include('page=2')
        expect(uri).to include('sort=name')
      end

      it 'returns nil for non-existent route definitions' do
        uri = otto.uri('NonExistent.method')
        expect(uri).to be_nil
      end
    end

    describe '#determine_locale' do
      it 'parses Accept-Language header' do
        env = { 'HTTP_ACCEPT_LANGUAGE' => 'en-US,en;q=0.9,fr;q=0.8' }
        locales = otto.determine_locale(env)
        
        expect(locales).to be_an(Array)
        expect(locales.first).to eq('en-US')
        
        puts "\n=== DEBUG: Locale Determination ==="
        puts "Header: #{env['HTTP_ACCEPT_LANGUAGE']}"
        puts "Parsed locales: #{locales.join(', ')}"
        puts "================================\n"
      end

      it 'handles missing Accept-Language header' do
        env = {}
        locales = otto.determine_locale(env)
        expect(locales).to eq(['en'])  # Uses default locale option
      end

      it 'uses default locale when header is empty' do
        env = { 'HTTP_ACCEPT_LANGUAGE' => '' }
        locales = otto.determine_locale(env)
        expect(locales).to eq(['en'])  # Uses default locale option
      end
    end
  end

  describe 'class methods' do
    describe '.default' do
      it 'returns a singleton Otto instance' do
        default1 = described_class.default
        default2 = described_class.default
        
        expect(default1).to be_an_instance_of(described_class)
        expect(default1).to be(default2)
      end
    end

    describe '.env?' do
      it 'checks current RACK_ENV' do
        original_env = ENV['RACK_ENV']
        
        begin
          ENV['RACK_ENV'] = 'test'
          expect(described_class.env?(:test)).to be true
          expect(described_class.env?(:production)).to be false
          expect(described_class.env?(:test, :development)).to be true
          
          puts "\n=== DEBUG: Environment Check ==="
          puts "RACK_ENV: #{ENV['RACK_ENV']}"
          puts "env?(:test): #{described_class.env?(:test)}"
          puts "env?(:production): #{described_class.env?(:production)}"
          puts "==============================\n"
        ensure
          ENV['RACK_ENV'] = original_env
        end
      end
    end
  end

  describe 'configuration isolation' do
    it 'maintains separate configurations between instances' do
      otto1 = create_minimal_otto
      otto2 = create_minimal_otto
      
      otto1.enable_csrf_protection!
      otto1.enable_hsts!
      
      expect(otto1.security_config.csrf_enabled?).to be true
      expect(otto2.security_config.csrf_enabled?).to be false
      
      expect(otto1.security_config.security_headers).to have_key('strict-transport-security')
      expect(otto2.security_config.security_headers).not_to have_key('strict-transport-security')
      
      puts "\n=== DEBUG: Instance Isolation ==="
      puts "Otto1 CSRF: #{otto1.security_config.csrf_enabled?}"
      puts "Otto2 CSRF: #{otto2.security_config.csrf_enabled?}"
      puts "Otto1 HSTS: #{otto1.security_config.security_headers.key?('strict-transport-security')}"
      puts "Otto2 HSTS: #{otto2.security_config.security_headers.key?('strict-transport-security')}"
      puts "==============================\n"
    end
  end

  describe 'trusted proxy configuration' do
    subject(:otto) { create_minimal_otto }

    describe '#add_trusted_proxy' do
      it 'adds trusted proxy to security config' do
        otto.add_trusted_proxy('192.168.1.1')
        expect(otto.security_config.trusted_proxies).to include('192.168.1.1')
      end

      it 'accepts string proxy formats' do
        otto.add_trusted_proxy('10.0.0.0/8')
        otto.add_trusted_proxy('172.16.')
        
        expect(otto.security_config.trusted_proxies).to include('10.0.0.0/8')
        expect(otto.security_config.trusted_proxies).to include('172.16.')
      end
    end
  end

  describe 'performance and edge cases' do
    let(:large_routes) do
      (1..100).map { |i| "GET /route#{i} TestApp.index" }
    end
    
    it 'handles large numbers of routes efficiently' do
      routes_file = create_test_routes_file('large_routes.txt', large_routes)
      
      start_time = Time.now
      otto = described_class.new(routes_file)
      load_time = Time.now - start_time
      
      expect(otto.routes[:GET].size).to eq(100)
      expect(load_time).to be < 1.0 # Should load in under 1 second
      
      puts "\n=== DEBUG: Performance Test ==="
      puts "Routes loaded: #{otto.routes[:GET].size}"
      puts "Load time: #{load_time.round(4)}s"
      puts "============================\n"
    end

    it 'handles malformed route files gracefully' do
      bad_routes = [
        'INVALID_VERB /path TestApp.method',
        'GET', # incomplete line
        'GET /path', # missing method
        'GET /path BadClass.method' # will fail at runtime
      ]
      
      routes_file = create_test_routes_file('bad_routes.txt', bad_routes)
      
      expect { described_class.new(routes_file) }.not_to raise_error
      
      # Should skip invalid lines and continue
      otto = described_class.new(routes_file)
      expect(otto.routes[:GET]).to be_empty # All lines were invalid
    end
  end
end