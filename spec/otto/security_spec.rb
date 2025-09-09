# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'security features' do
  subject(:otto) { create_minimal_otto }

  describe 'security header methods' do
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
        otto.enable_hsts!(max_age: 86_400, include_subdomains: false)
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
          'x-custom-header' => 'test-value',
        }

        otto.set_security_headers(custom_headers)

        expect(otto.security_config.security_headers['permissions-policy']).to eq('geolocation=()')
        expect(otto.security_config.security_headers['x-custom-header']).to eq('test-value')
        expect(otto.security_config.security_headers['x-content-type-options']).to eq('nosniff')
      end
    end
  end

  describe 'middleware management' do
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

  describe 'trusted proxy configuration' do
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
end
