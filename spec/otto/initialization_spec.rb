# frozen_string_literal: true
# spec/otto/initialization_spec.rb

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
      'GET /instance/:id TestInstanceApp#show',
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

    it 'initializes middleware stack with IP privacy by default' do
      expect(otto.middleware_stack).to include(Otto::Security::Middleware::IPPrivacyMiddleware)
      expect(otto.security_config.ip_privacy_config.enabled?).to be true
    end
  end

  context 'with routes file' do
    let(:routes_file) { create_test_routes_file('common_routes.txt', test_routes) }
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
      expect(otto.routes_literal[:GET]).to have_key('') # "/" becomes "" after gsub
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
        security_headers: { 'custom-header' => 'custom-value' },
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
      otto1 = Otto.new(nil, csrf_protection: true, security_headers: { 'strict-transport-security' => 'max-age=31536000; includeSubDomains' })
      otto2 = create_minimal_otto

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

      start_time = Otto::Utils.now_in_μs
      otto = described_class.new(routes_file)
      load_time = Otto::Utils.now_in_μs - start_time

      expect(otto.routes[:GET].size).to eq(100)
      expect(load_time).to be < 100_000 # Should load well under 100 ms

      puts "\n=== DEBUG: Performance Test ==="
      puts "Routes loaded: #{otto.routes[:GET].size}"
      puts "Load time: #{load_time}μs"
      puts "============================\n"
    end

    it 'handles malformed route files gracefully' do
      bad_routes = [
        'INVALID_VERB /path TestApp.method',
        'GET', # incomplete line
        'GET /path', # missing method
        'GET /path BadClass.method', # will fail at runtime
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
        original_env = ENV.fetch('RACK_ENV', nil)

        begin
          ENV['RACK_ENV'] = 'test'
          expect(described_class.env?(:test)).to be true
          expect(described_class.env?(:production)).to be false
          expect(described_class.env?(:test, :development)).to be true

          puts "\n=== DEBUG: Environment Check ==="
          puts "RACK_ENV: #{ENV.fetch('RACK_ENV', nil)}"
          puts "env?(:test): #{described_class.env?(:test)}"
          puts "env?(:production): #{described_class.env?(:production)}"
          puts "==============================\n"
        ensure
          ENV['RACK_ENV'] = original_env
        end
      end
    end
  end

  describe 'lazy configuration freezing' do
    let(:routes_file) { create_test_routes_file('common_routes.txt', ['GET / TestApp.index']) }

    # Note: These tests run in RSpec environment where auto-freezing is disabled.
    # We manually test the freezing behavior to verify the mechanism works.

    context 'multi-step initialization pattern' do
      it 'allows configuration after initialization' do
        otto = described_class.new(routes_file)

        # Should allow adding auth strategies after initialization
        expect do
          otto.add_auth_strategy('test', Otto::Security::Authentication::Strategies::NoAuthStrategy.new)
        end.not_to raise_error

        # Should allow adding middleware after initialization
        expect do
          otto.use Otto::Security::Middleware::CSRFMiddleware
        end.not_to raise_error

        # Should allow enabling features after initialization
        expect do
          otto.enable_csrf_protection!
        end.not_to raise_error
      end

      it 'manually freezes configuration when requested' do
        otto = described_class.new(routes_file)

        # Before freezing: modifications allowed
        expect do
          otto.add_auth_strategy('test', Otto::Security::Authentication::Strategies::NoAuthStrategy.new)
        end.not_to raise_error

        # Manually freeze
        otto.freeze_configuration!

        # After freezing: modifications raise FrozenError
        expect do
          otto.add_auth_strategy('another', Otto::Security::Authentication::Strategies::NoAuthStrategy.new)
        end.to raise_error(FrozenError, 'Cannot modify frozen configuration')
      end

      it 'freezes configuration only once' do
        otto = described_class.new(routes_file)

        # Freeze twice should not raise error
        expect do
          otto.freeze_configuration!
          otto.freeze_configuration!
        end.not_to raise_error

        # But modifications should still be blocked
        expect do
          otto.enable_csrf_protection!
        end.to raise_error(FrozenError)
      end

      it 'provides frozen_configuration? check' do
        otto = described_class.new(routes_file)

        expect(otto.frozen_configuration?).to be false

        otto.freeze_configuration!

        expect(otto.frozen_configuration?).to be true
      end
    end

    context 'registry-based multi-app pattern (like OneTime Secret)' do
      it 'supports building multiple Otto apps with deferred freezing' do
        # Simulate OneTime Secret's registry pattern
        apps = {}

        # Step 1: Create multiple Otto instances
        apps[:api_v1] = described_class.new(create_test_routes_file('api_v1.txt', ['GET /api/v1 TestApp.index']))
        apps[:api_v2] = described_class.new(create_test_routes_file('api_v2.txt', ['GET /api/v2 TestApp.index']))

        # Step 2: Configure each app independently
        apps[:api_v1].add_auth_strategy('session', Otto::Security::Authentication::Strategies::NoAuthStrategy.new)
        apps[:api_v2].add_auth_strategy('api_key', Otto::Security::Authentication::Strategies::NoAuthStrategy.new)

        # Step 3: All apps configured successfully before any requests
        expect(apps[:api_v1].auth_config[:auth_strategies]).to have_key('session')
        expect(apps[:api_v2].auth_config[:auth_strategies]).to have_key('api_key')

        # Step 4: Manual freeze for production
        apps.each_value(&:freeze_configuration!)

        # Step 5: All apps now frozen
        expect(apps[:api_v1].frozen_configuration?).to be true
        expect(apps[:api_v2].frozen_configuration?).to be true
      end
    end
  end
end
