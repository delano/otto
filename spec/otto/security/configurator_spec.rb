# spec/otto/security/configurator_spec.rb

require 'spec_helper'

RSpec.describe Otto::Security::Configurator do
  let(:security_config) { Otto::Security::Config.new }
  let(:middleware_stack) { Otto::Core::MiddlewareStack.new }
  let(:configurator) { described_class.new(security_config, middleware_stack) }

  describe '#initialize' do
    it 'initializes with security config and middleware stack' do
      expect(configurator.security_config).to eq(security_config)
      expect(configurator.middleware_stack).to eq(middleware_stack)
    end

    it 'initializes auth config with defaults' do
      expect(configurator.auth_config).to eq(
        auth_strategies: {},
        default_auth_strategy: 'noauth'
      )
    end
  end

  describe '#configure' do
    it 'configures all security options at once' do
      configurator.configure(
        csrf_protection: true,
        request_validation: true,
        rate_limiting: { requests_per_minute: 50 },
        trusted_proxies: ['127.0.0.1'],
        security_headers: { 'X-Custom' => 'value' },
        hsts: true,
        csp: true,
        frame_protection: true,
        authentication: true
      )

      # Verify CSRF protection enabled
      expect(security_config.csrf_enabled?).to be true
      expect(middleware_stack.includes?(Otto::Security::CSRFMiddleware)).to be true

      # Verify request validation enabled
      expect(security_config.input_validation).to be true
      expect(middleware_stack.includes?(Otto::Security::ValidationMiddleware)).to be true

      # Verify rate limiting configured
      expect(middleware_stack.includes?(Otto::Security::RateLimitMiddleware)).to be true
      expect(security_config.rate_limiting_config[:requests_per_minute]).to eq(50)

      # Verify trusted proxies added
      expect(security_config.trusted_proxy?('127.0.0.1')).to be true

      # Verify security headers set
      expect(security_config.security_headers['X-Custom']).to eq('value')

      # Verify HSTS enabled
      expect(security_config.security_headers['strict-transport-security']).to include('max-age=31536000')

      # Verify CSP enabled
      expect(security_config.security_headers['content-security-policy']).to eq("default-src 'self'")

      # Verify frame protection enabled
      expect(security_config.security_headers['x-frame-options']).to eq('SAMEORIGIN')

      # Verify authentication enabled
      expect(middleware_stack.includes?(Otto::Security::AuthenticationMiddleware)).to be true
    end

    it 'handles boolean rate limiting option' do
      configurator.configure(rate_limiting: true)

      expect(middleware_stack.includes?(Otto::Security::RateLimitMiddleware)).to be true
      # Should use defaults when boolean true is passed
    end

    it 'handles hash rate limiting option' do
      configurator.configure(rate_limiting: { requests_per_minute: 30, custom_rules: { 'api' => { limit: 10 } } })

      expect(middleware_stack.includes?(Otto::Security::RateLimitMiddleware)).to be true
      expect(security_config.rate_limiting_config[:requests_per_minute]).to eq(30)
      expect(security_config.rate_limiting_config[:custom_rules]['api']).to eq(limit: 10)
    end

    it 'handles array of trusted proxies' do
      proxies = ['127.0.0.1', '10.0.0.0/8', /^192\.168\./]
      configurator.configure(trusted_proxies: proxies)

      proxies.each do |proxy|
        case proxy
        when String
          expect(security_config.trusted_proxy?(proxy)).to be true
        when Regexp
          expect(security_config.trusted_proxy?('192.168.1.1')).to be true
        end
      end
    end

    it 'handles single trusted proxy string' do
      configurator.configure(trusted_proxies: '127.0.0.1')

      expect(security_config.trusted_proxy?('127.0.0.1')).to be true
    end

    it 'skips empty security headers' do
      original_headers = security_config.security_headers.dup
      configurator.configure(security_headers: {})

      expect(security_config.security_headers).to eq(original_headers)
    end

    it 'configures only specified options' do
      configurator.configure(csrf_protection: true)

      # Only CSRF should be enabled
      expect(security_config.csrf_enabled?).to be true
      expect(middleware_stack.includes?(Otto::Security::CSRFMiddleware)).to be true

      # Others should remain disabled
      expect(security_config.input_validation).to be true # This is enabled by default
      expect(middleware_stack.includes?(Otto::Security::ValidationMiddleware)).to be false
      expect(middleware_stack.includes?(Otto::Security::RateLimitMiddleware)).to be false
    end

    it 'can be called multiple times' do
      configurator.configure(csrf_protection: true)
      configurator.configure(request_validation: true)

      expect(security_config.csrf_enabled?).to be true
      expect(security_config.input_validation).to be true
      expect(middleware_stack.includes?(Otto::Security::CSRFMiddleware)).to be true
      expect(middleware_stack.includes?(Otto::Security::ValidationMiddleware)).to be true
    end
  end

  describe '#enable_csrf_protection!' do
    it 'enables CSRF protection and adds middleware' do
      configurator.enable_csrf_protection!

      expect(security_config.csrf_enabled?).to be true
      expect(middleware_stack.includes?(Otto::Security::CSRFMiddleware)).to be true
    end

    it 'does not add duplicate middleware' do
      configurator.enable_csrf_protection!
      configurator.enable_csrf_protection!

      expect(middleware_stack.middleware_list.count(Otto::Security::CSRFMiddleware)).to eq(1)
    end
  end

  describe '#add_rate_limit_rule' do
    it 'adds custom rate limiting rule' do
      configurator.add_rate_limit_rule('uploads', limit: 5, period: 300)

      rules = security_config.rate_limiting_config[:custom_rules]
      expect(rules['uploads']).to eq(limit: 5, period: 300)
    end

    it 'converts symbol names to strings' do
      configurator.add_rate_limit_rule(:api_calls, limit: 10)

      rules = security_config.rate_limiting_config[:custom_rules]
      expect(rules['api_calls']).to eq(limit: 10)
    end
  end

  describe '#add_auth_strategy' do
    let(:test_strategy) { double('TestStrategy') }

    it 'adds authentication strategy and enables middleware' do
      configurator.add_auth_strategy('test', test_strategy)

      expect(configurator.auth_config[:auth_strategies]['test']).to eq(test_strategy)
      expect(middleware_stack.includes?(Otto::Security::AuthenticationMiddleware)).to be true
    end
  end

  describe '#configure_auth_strategies' do
    let(:strategies) do
      {
        'public' => double('PublicStrategy'),
        'admin' => double('AdminStrategy'),
      }
    end

    it 'configures multiple auth strategies' do
      configurator.configure_auth_strategies(strategies, default_strategy: 'public')

      expect(configurator.auth_config[:auth_strategies]).to eq(strategies)
      expect(configurator.auth_config[:default_auth_strategy]).to eq('public')
    end

    it 'enables authentication middleware when strategies provided' do
      configurator.configure_auth_strategies(strategies)

      expect(middleware_stack.includes?(Otto::Security::AuthenticationMiddleware)).to be true
    end

    it 'does not enable middleware for empty strategies' do
      configurator.configure_auth_strategies({})

      expect(middleware_stack.includes?(Otto::Security::AuthenticationMiddleware)).to be false
    end
  end

  describe 'security header methods' do
    describe '#security_headers=' do
      it 'merges headers with existing ones' do
        original_headers = security_config.security_headers.dup
        configurator.security_headers = { 'X-Custom' => 'test' }

        expect(security_config.security_headers).to include(original_headers)
        expect(security_config.security_headers['X-Custom']).to eq('test')
      end
    end

    describe '#enable_hsts!' do
      it 'enables HSTS with default options' do
        configurator.enable_hsts!

        hsts_header = security_config.security_headers['strict-transport-security']
        expect(hsts_header).to include('max-age=31536000')
        expect(hsts_header).to include('includeSubDomains')
      end

      it 'accepts custom options' do
        configurator.enable_hsts!(max_age: 86_400, include_subdomains: false)

        hsts_header = security_config.security_headers['strict-transport-security']
        expect(hsts_header).to eq('max-age=86400')
      end
    end

    describe '#enable_csp!' do
      it 'enables CSP with default policy' do
        configurator.enable_csp!

        expect(security_config.security_headers['content-security-policy']).to eq("default-src 'self'")
      end

      it 'accepts custom policy' do
        custom_policy = "default-src 'self'; script-src 'self' 'unsafe-inline'"
        configurator.enable_csp!(custom_policy)

        expect(security_config.security_headers['content-security-policy']).to eq(custom_policy)
      end
    end

    describe '#enable_frame_protection!' do
      it 'enables frame protection with default option' do
        configurator.enable_frame_protection!

        expect(security_config.security_headers['x-frame-options']).to eq('SAMEORIGIN')
      end

      it 'accepts custom option' do
        configurator.enable_frame_protection!('DENY')

        expect(security_config.security_headers['x-frame-options']).to eq('DENY')
      end
    end
  end
end
