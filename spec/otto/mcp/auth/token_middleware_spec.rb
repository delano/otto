# spec/otto/mcp/auth/token_middleware_spec.rb
#
# frozen_string_literal: true

require_relative '../../../spec_helper'

RSpec.describe Otto::MCP::Auth::TokenMiddleware do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['OK']] } }
  let(:security_config) { Otto::Security::Config.new }

  def mcp_env(headers = {})
    { 'PATH_INFO' => '/_mcp', 'REQUEST_METHOD' => 'POST' }.merge(headers)
  end

  describe 'fail-closed behavior (issue #258)' do
    it 'returns 401 when the security config carries no authenticator' do
      status, headers, body = described_class.new(app, security_config).call(mcp_env)

      expect(status).to eq(401)
      expect(headers['content-type']).to eq('application/json')
      expect(JSON.parse(body.join).dig('error', 'message')).to eq('Unauthorized')
    end

    it 'returns 401 when no security config was supplied at all' do
      status, = described_class.new(app).call(mcp_env('HTTP_AUTHORIZATION' => 'Bearer abc'))

      expect(status).to eq(401)
    end

    it 'returns 401 when the authenticator is cleared after mounting' do
      security_config.mcp_auth = Otto::MCP::Auth::TokenAuth.new(['abc'])
      middleware = described_class.new(app, security_config)
      expect(middleware.call(mcp_env('HTTP_AUTHORIZATION' => 'Bearer abc')).first).to eq(200)

      security_config.mcp_auth = nil

      expect(middleware.call(mcp_env('HTTP_AUTHORIZATION' => 'Bearer abc')).first).to eq(401)
    end
  end

  describe 'non-MCP paths' do
    it 'passes through without consulting the authenticator' do
      status, = described_class.new(app, security_config).call('PATH_INFO' => '/other')

      expect(status).to eq(200)
    end

    it 'honors the endpoint advertised in env' do
      env = { 'PATH_INFO' => '/api/mcp', 'otto.mcp_http_endpoint' => '/api/mcp' }

      expect(described_class.new(app, security_config).call(env).first).to eq(401)
    end
  end

  describe 'Otto::Security::Config#mcp_auth= (the authenticator this middleware reads)' do
    subject(:config) { Otto::Security::Config.new }

    it 'accepts an authenticator' do
      auth = Otto::MCP::Auth::TokenAuth.new(['abc'])
      config.mcp_auth = auth

      expect(config.mcp_auth).to be(auth)
    end

    it 'accepts any object responding to #authenticate' do
      duck = Class.new { define_method(:authenticate) { |_env| true } }.new
      config.mcp_auth = duck

      expect(config.mcp_auth).to be(duck)
    end

    it 'accepts nil, which fails the middleware closed' do
      config.mcp_auth = Otto::MCP::Auth::TokenAuth.new(['abc'])
      config.mcp_auth = nil

      expect(config.mcp_auth).to be_nil
    end

    it 'rejects an object that cannot authenticate' do
      expect { config.mcp_auth = Object.new }
        .to raise_error(ArgumentError, /must respond to #authenticate.*got Object/)
    end

    it 'rejects a bare token String' do
      expect { config.mcp_auth = 'a-token' }
        .to raise_error(ArgumentError, /must respond to #authenticate/)
    end

    it 'leaves the previous authenticator in place after a rejected assignment' do
      auth = Otto::MCP::Auth::TokenAuth.new(['abc'])
      config.mcp_auth = auth
      expect { config.mcp_auth = Object.new }.to raise_error(ArgumentError)

      expect(config.mcp_auth).to be(auth)
    end

    it 'raises when the configuration is frozen' do
      config.freeze

      expect { config.mcp_auth = Otto::MCP::Auth::TokenAuth.new(['abc']) }
        .to raise_error(FrozenError, /Cannot modify frozen configuration/)
    end
  end
end
