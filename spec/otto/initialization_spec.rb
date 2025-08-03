# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'initialization' do
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
end