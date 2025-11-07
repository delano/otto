# spec/otto/rate_limiting_spec.rb

# spec/otto/rate_limiting_spec.rb

require 'spec_helper'

RSpec.describe Otto, 'rate limiting features' do
  subject(:otto) { create_minimal_otto }

  before do
    # Skip rate limiting tests if rack-attack is not available
    skip 'rack-attack not available' unless defined?(Rack::Attack)
  end

  describe '#enable_rate_limiting!' do
    it 'enables rate limiting with default settings' do
      otto.enable_rate_limiting!

      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be true
      expect(otto.security_config.rate_limiting_config).to be_a(Hash)
    end

    it 'accepts custom rate limiting options' do
      otto.enable_rate_limiting!(requests_per_minute: 50)

      expect(otto.security_config.rate_limiting_config[:requests_per_minute]).to eq(50)
    end

    it 'does not add middleware twice when called multiple times' do
      otto.enable_rate_limiting!
      otto.enable_rate_limiting! # repeated intentionally for this testcase

      middleware_count = otto.middleware.middleware_list.count(Otto::Security::RateLimitMiddleware)
      expect(middleware_count).to eq(1)
    end
  end

  describe '#configure_rate_limiting' do
    it 'configures rate limiting settings' do
      config = {
        requests_per_minute: 75,
        custom_rules: {
          'api_calls' => { limit: 30, period: 60 },
        },
      }

      otto.configure_rate_limiting(config)

      expect(otto.security_config.rate_limiting_config[:requests_per_minute]).to eq(75)
      expect(otto.security_config.rate_limiting_config[:custom_rules]['api_calls'][:limit]).to eq(30)
    end

    it 'merges with existing configuration' do
      otto.configure_rate_limiting(requests_per_minute: 50)
      otto.configure_rate_limiting(custom_rules: { 'uploads' => { limit: 5 } })

      config = otto.security_config.rate_limiting_config
      expect(config[:requests_per_minute]).to eq(50)
      expect(config[:custom_rules]['uploads'][:limit]).to eq(5)
    end
  end

  describe '#add_rate_limit_rule' do
    it 'adds a custom rate limiting rule' do
      otto.add_rate_limit_rule('uploads', limit: 5, period: 300)

      rules = otto.security_config.rate_limiting_config[:custom_rules]
      expect(rules['uploads'][:limit]).to eq(5)
      expect(rules['uploads'][:period]).to eq(300)
    end

    it 'accepts symbol names and converts to string' do
      otto.add_rate_limit_rule(:api_heavy, limit: 10)

      rules = otto.security_config.rate_limiting_config[:custom_rules]
      expect(rules['api_heavy'][:limit]).to eq(10)
    end

    it 'supports condition procs' do
      condition = ->(req) { req.post? }
      otto.add_rate_limit_rule('posts', limit: 20, condition: condition)

      rules = otto.security_config.rate_limiting_config[:custom_rules]
      expect(rules['posts'][:condition]).to eq(condition)
    end
  end

  describe 'initialization with rate_limiting option' do
    it 'enables rate limiting when rate_limiting: true' do
      otto = Otto.new(nil, rate_limiting: true)

      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be true
    end

    it 'configures rate limiting when rate_limiting is a hash' do
      options = { requests_per_minute: 80 }
      otto = Otto.new(nil, rate_limiting: options)

      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be true
      expect(otto.security_config.rate_limiting_config[:requests_per_minute]).to eq(80)
    end

    it 'does not enable rate limiting when rate_limiting is false' do
      otto = Otto.new(nil, rate_limiting: false)

      expect(otto.middleware.includes?(Otto::Security::RateLimitMiddleware)).to be false
    end
  end

  describe 'Otto::Security::RateLimiting' do
    describe '.configure_rack_attack!' do
      before do
        # Clear any existing Rack::Attack configuration
        if defined?(Rack::Attack)
          if Rack::Attack.respond_to?(:clear_configuration)
            Rack::Attack.clear_configuration
          else
            Rack::Attack.clear!
          end
        end
      end

      it 'configures basic rate limiting rules' do
        config = { requests_per_minute: 120 }
        Otto::Security::RateLimiting.configure_rack_attack!(config)

        # Check that throttles were configured
        expect(Rack::Attack.throttles).to have_key('requests')
      end

      it 'configures custom rules' do
        config = {
          custom_rules: {
            'heavy_api' => { limit: 10, period: 60 },
          },
        }
        Otto::Security::RateLimiting.configure_rack_attack!(config)

        expect(Rack::Attack.throttles).to have_key('heavy_api')
      end

      it 'skips configuration when rack-attack is not available' do
        # Temporarily hide Rack::Attack
        rack_attack = Object.send(:remove_const, :Rack) if defined?(Rack::Attack)

        expect { Otto::Security::RateLimiting.configure_rack_attack!({}) }.not_to raise_error

        # Restore Rack::Attack
        Object.const_set(:Rack, rack_attack) if rack_attack
      end
    end
  end

  describe 'Otto::Security::RateLimitMiddleware' do
    let(:app) { ->(_env) { [200, {}, ['OK']] } }
    let(:security_config) { otto.security_config }
    let(:middleware) { Otto::Security::RateLimitMiddleware.new(app, security_config) }

    it 'initializes without errors when rack-attack is available' do
      expect { middleware }.not_to raise_error
    end

    it 'logs warning when rack-attack is not available' do
      # Hide Rack::Attack temporarily
      rack_attack = Object.send(:remove_const, :Rack) if defined?(Rack::Attack)

      expect(Otto.logger).to receive(:warn).with(match(/rack-attack not available/))
      Otto::Security::RateLimitMiddleware.new(app, security_config)

      # Restore Rack::Attack
      Object.const_set(:Rack, rack_attack) if rack_attack
    end

    it 'calls through to app when rate limiting is available' do
      env = Rack::MockRequest.env_for('/')
      status, _headers, body = middleware.call(env)

      expect(status).to eq(200)
      expect(body).to eq(['OK'])
    end
  end
end
