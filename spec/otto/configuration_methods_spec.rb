# spec/otto/configuration_methods_spec.rb

# spec/otto/configuration_methods_spec.rb

require 'spec_helper'

RSpec.describe Otto, 'Configuration Methods' do
  describe '#configure_locale' do
    context 'with no locale configuration' do
      it 'does not create locale_config when no options provided' do
        app = Otto.new
        app.send(:configure_locale, {})

        expect(app.instance_variable_get(:@locale_config)).to be_nil
      end
    end

    context 'with direct instance options' do
      it 'sets available_locales from direct options' do
        app = Otto.new
        opts = { available_locales: %w[en es fr] }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.available_locales).to eq(%w[en es fr])
      end

      it 'sets default_locale from direct options' do
        app = Otto.new
        opts = { default_locale: 'fr' }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.default_locale).to eq('fr')
      end

      it 'sets both available_locales and default_locale' do
        app = Otto.new
        opts = {
          available_locales: %w[en jp],
          default_locale: 'jp',
        }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.available_locales).to eq(%w[en jp])
        expect(config.default_locale).to eq('jp')
      end
    end

    context 'with legacy locale_config hash' do
      it 'supports legacy available_locales key' do
        app = Otto.new
        opts = {
          locale_config: {
            available_locales: %w[en pt],
          },
        }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.available_locales).to eq(%w[en pt])
      end

      it 'supports legacy available key (alias)' do
        app = Otto.new
        opts = {
          locale_config: {
            available: %w[en ru],
          },
        }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.available_locales).to eq(%w[en ru])
      end

      it 'supports legacy default_locale key' do
        app = Otto.new
        opts = {
          locale_config: {
            default_locale: 'ru',
          },
        }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.default_locale).to eq('ru')
      end

      it 'supports legacy default key (alias)' do
        app = Otto.new
        opts = {
          locale_config: {
            default: 'pt',
          },
        }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.default_locale).to eq('pt')
      end

      it 'prioritizes available_locales over available' do
        app = Otto.new
        opts = {
          locale_config: {
            available_locales: %w[en zh],
            available: %w[en ko],
          },
        }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.available_locales).to eq(%w[en zh])
      end

      it 'prioritizes default_locale over default' do
        app = Otto.new
        opts = {
          locale_config: {
            default_locale: 'zh',
            default: 'ko',
          },
        }

        app.send(:configure_locale, opts)

        config = app.instance_variable_get(:@locale_config)
        expect(config.default_locale).to eq('zh')
      end
    end
  end

  describe '#configure_security' do
    let(:app) { Otto.new }

    it 'enables CSRF protection when requested' do
      expect(app).to receive(:enable_csrf_protection!)

      app.send(:configure_security, { csrf_protection: true })
    end

    it 'does not enable CSRF protection when not requested' do
      expect(app).not_to receive(:enable_csrf_protection!)

      app.send(:configure_security, {})
    end

    it 'enables request validation when requested' do
      expect(app).to receive(:enable_request_validation!)

      app.send(:configure_security, { request_validation: true })
    end

    it 'does not enable request validation when not requested' do
      expect(app).not_to receive(:enable_request_validation!)

      app.send(:configure_security, {})
    end

    it 'enables rate limiting with default options' do
      expect(app).to receive(:enable_rate_limiting!).with({})

      app.send(:configure_security, { rate_limiting: true })
    end

    it 'enables rate limiting with custom options' do
      rate_opts = { max_requests: 100, window: 3600 }
      expect(app).to receive(:enable_rate_limiting!).with(rate_opts)

      app.send(:configure_security, { rate_limiting: rate_opts })
    end

    it 'does not enable rate limiting when not requested' do
      expect(app).not_to receive(:enable_rate_limiting!)

      app.send(:configure_security, {})
    end

    it 'adds trusted proxies when provided as array' do
      proxies = ['127.0.0.1', '10.0.0.0/8', '192.168.1.0/24']

      proxies.each do |proxy|
        expect(app).to receive(:add_trusted_proxy).with(proxy)
      end

      app.send(:configure_security, { trusted_proxies: proxies })
    end

    it 'adds trusted proxy when provided as single value' do
      expect(app).to receive(:add_trusted_proxy).with('127.0.0.1')

      app.send(:configure_security, { trusted_proxies: '127.0.0.1' })
    end

    it 'does not add trusted proxies when not provided' do
      expect(app).not_to receive(:add_trusted_proxy)

      app.send(:configure_security, {})
    end

    it 'sets custom security headers when provided' do
      headers = { 'X-Custom-Security' => 'enabled' }
      expect(app).to receive(:set_security_headers).with(headers)

      app.send(:configure_security, { security_headers: headers })
    end

    it 'does not set security headers when not provided' do
      expect(app).not_to receive(:set_security_headers)

      app.send(:configure_security, {})
    end

    it 'handles multiple security options together' do
      expect(app).to receive(:enable_csrf_protection!)
      expect(app).to receive(:enable_request_validation!)
      expect(app).to receive(:enable_rate_limiting!).with({})
      expect(app).to receive(:add_trusted_proxy).with('127.0.0.1')
      expect(app).to receive(:set_security_headers).with({ 'X-Test' => 'value' })

      app.send(:configure_security, {
                 csrf_protection: true,
        request_validation: true,
        rate_limiting: true,
        trusted_proxies: '127.0.0.1',
        security_headers: { 'X-Test' => 'value' },
               })
    end
  end

  describe '#configure_authentication' do
    let(:app) { Otto.new }

    it 'sets up auth_config with default values' do
      app.send(:configure_authentication, {})

      config = app.instance_variable_get(:@auth_config)
      expect(config[:auth_strategies]).to eq({})
      expect(config[:default_auth_strategy]).to eq('noauth')
    end

    it 'sets custom auth strategies' do
      strategies = { 'admin' => 'AdminAuth', 'user' => 'UserAuth' }
      app.send(:configure_authentication, { auth_strategies: strategies })

      config = app.instance_variable_get(:@auth_config)
      expect(config[:auth_strategies]).to eq(strategies)
    end

    it 'sets custom default auth strategy' do
      app.send(:configure_authentication, { default_auth_strategy: 'admin' })

      config = app.instance_variable_get(:@auth_config)
      expect(config[:default_auth_strategy]).to eq('admin')
    end

    it 'configures auth strategies when provided' do
      strategies = { 'admin' => 'AdminAuth' }
      app.send(:configure_authentication, { auth_strategies: strategies })

      config = app.instance_variable_get(:@auth_config)
      expect(config[:auth_strategies]).to eq(strategies)
    end

    it 'configures default auth config when no strategies provided' do
      app.send(:configure_authentication, {})

      config = app.instance_variable_get(:@auth_config)
      expect(config[:auth_strategies]).to eq({})
    end

    it 'configures empty strategies correctly' do
      app.send(:configure_authentication, { auth_strategies: {} })

      config = app.instance_variable_get(:@auth_config)
      expect(config[:auth_strategies]).to eq({})
    end
  end

  describe '#configure_mcp' do
    let(:app) { Otto.new }

    before do
      # Mock the Otto::MCP::Server class
      stub_const('Otto::MCP::Server', Class.new do
        def initialize(otto_instance); end
        def enable!(options); end
      end)
    end

    it 'does not initialize MCP server when not requested' do
      app.send(:configure_mcp, {})

      expect(app.instance_variable_get(:@mcp_server)).to be_nil
    end

    it 'initializes MCP server when mcp_enabled is true' do
      app.send(:configure_mcp, { mcp_enabled: true })

      server = app.instance_variable_get(:@mcp_server)
      expect(server).to be_a(Otto::MCP::Server)
    end

    it 'initializes MCP server when mcp_http is true' do
      app.send(:configure_mcp, { mcp_http: true })

      server = app.instance_variable_get(:@mcp_server)
      expect(server).to be_a(Otto::MCP::Server)
    end

    it 'initializes MCP server when mcp_stdio is true' do
      app.send(:configure_mcp, { mcp_stdio: true })

      server = app.instance_variable_get(:@mcp_server)
      expect(server).to be_a(Otto::MCP::Server)
    end

    it 'does not enable MCP server when mcp_http is explicitly false' do
      server_double = instance_double(Otto::MCP::Server)
      allow(Otto::MCP::Server).to receive(:new).and_return(server_double)
      expect(server_double).not_to receive(:enable!)

      app.send(:configure_mcp, { mcp_enabled: true, mcp_http: false })
    end

    it 'enables MCP server with default options' do
      server_double = instance_double(Otto::MCP::Server)
      allow(Otto::MCP::Server).to receive(:new).and_return(server_double)
      expect(server_double).to receive(:enable!).with({})

      app.send(:configure_mcp, { mcp_enabled: true })
    end

    it 'enables MCP server with custom endpoint' do
      server_double = instance_double(Otto::MCP::Server)
      allow(Otto::MCP::Server).to receive(:new).and_return(server_double)
      expect(server_double).to receive(:enable!).with({ http_endpoint: '/custom-mcp' })

      app.send(:configure_mcp, {
                 mcp_enabled: true,
        mcp_endpoint: '/custom-mcp',
               })
    end
  end

  describe '#middleware_enabled?' do
    let(:app) { Otto.new }

    it 'returns false when middleware is not in stack' do
      middleware_class = Class.new

      result = app.send(:middleware_enabled?, middleware_class)

      expect(result).to be false
    end

    it 'returns true when middleware is in stack' do
      middleware_class = Class.new
      app.middleware.add(middleware_class)

      result = app.send(:middleware_enabled?, middleware_class)

      expect(result).to be true
    end
  end
end
