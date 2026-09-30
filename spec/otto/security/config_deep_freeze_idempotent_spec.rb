# spec/otto/security/config_deep_freeze_idempotent_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Otto#call skips its lazy configuration freeze under RSpec, so the MCP specs
# never serve a request through a frozen configuration. Outside RSpec the first
# request runs freeze_configuration!, which deep-freezes the security config
# and then the middleware stack. The MCP token and rate limit middleware
# entries carry the security config as a middleware argument, so walking the
# stack reaches the already-frozen config a second time. Config#deep_freeze!
# used to rerun its freeze-time validators on that second visit and raise
# FrozenError, which failed every request. These examples freeze explicitly,
# the way the first production request does, and then serve requests.
RSpec.describe Otto::Security::Config, '#deep_freeze!' do
  describe 'on an already frozen config' do
    it 'returns self without raising' do
      config = described_class.new
      config.deep_freeze!

      expect(config.deep_freeze!).to be(config)
    end

    it 'returns self without raising when proxy trust is configured' do
      config = described_class.new
      config.add_trusted_proxy('10.0.0.0/8')
      config.deep_freeze!

      expect(config.deep_freeze!).to be(config)
    end

    # A frozen config cannot hold a stub or a counter, so a subclass records
    # each validator call in a closure array that deep_freeze! never reaches.
    it 'does not rerun the freeze-time validators' do
      calls    = []
      counting = Class.new(described_class) do
        define_method(:validate_referrer_policy!) do |policy|
          calls << :referrer_policy
          super(policy)
        end
        define_method(:validate_trusted_proxy_config!) do
          calls << :trusted_proxy
          super()
        end
        define_method(:validate_csrf_secret_config!) do
          calls << :csrf_secret
          super()
        end
        private :validate_referrer_policy!, :validate_trusted_proxy_config!, :validate_csrf_secret_config!
      end

      config = counting.new
      calls.clear # the constructor validates the default referrer policy
      config.deep_freeze!
      expect(calls).to eq(%i[referrer_policy trusted_proxy csrf_secret])

      calls.clear
      expect(config.deep_freeze!).to be(config)
      expect(calls).to be_empty
    end
  end

  # Object#freeze freezes only the config object. Its nested settings stay
  # mutable, so deep_freeze! must not treat it as already done.
  describe 'on a config frozen with Object#freeze' do
    it 'raises FrozenError instead of returning with mutable nested settings' do
      config = described_class.new
      config.freeze

      expect { config.deep_freeze! }
        .to raise_error(FrozenError, /frozen with Object#freeze.*nested settings are still mutable/)
      expect(config.security_headers).not_to be_frozen
    end

    it 'raises when the application also froze some nested settings by hand' do
      config = described_class.new
      config.security_headers.freeze
      config.rate_limiting_config.freeze
      config.freeze

      expect { config.deep_freeze! }.to raise_error(FrozenError, /frozen with Object#freeze/)
    end

    it 'makes freeze_configuration! raise for an Otto whose config was shallow-frozen' do
      otto = Otto.new(nil)
      otto.security_config.freeze

      expect { otto.freeze_configuration! }.to raise_error(FrozenError, /frozen with Object#freeze/)
    end

    it 'still returns self for a config that deep_freeze! froze' do
      config = described_class.new
      config.deep_freeze!

      expect(config.deep_freeze!).to be(config)
      expect(config.security_headers).to be_frozen
    end
  end

  describe 'Otto with MCP middleware after freeze_configuration!' do
    # MCP rate limiting rewrites the process-global Rack::Attack throttles.
    include_context 'with rack attack isolation'

    let(:token) { 'frozen-config-token' }

    def build_frozen_otto(**mcp_options)
      otto = Otto.new(nil, { mcp_enabled: true, mcp_http: true, mcp_validation: false }.merge(mcp_options))
      otto.freeze_configuration!
      otto
    end

    def mcp_call(otto, id:, headers: {})
      body = JSON.generate({ jsonrpc: '2.0', id: id, method: 'tools/list', params: {} })
      env  = Rack::MockRequest.env_for(
        '/_mcp',
        method: 'POST',
        input: body,
        'CONTENT_TYPE' => 'application/json'
      )
      headers.each { |key, value| env[key] = value }

      status, _headers, response_body = otto.call(env)
      [status, JSON.parse(response_body.to_a.join)]
    end

    def require_rate_limiting!
      Otto::Security::RateLimiting.ensure_available!
    rescue Otto::OptionalDependencyError => e
      skip e.message
    end

    shared_examples 'a frozen MCP app that keeps serving' do
      it 'freezes the configuration' do
        expect(otto.frozen_configuration?).to be(true)
        expect(otto.security_config).to be_frozen
      end

      it 'answers repeated authorized requests' do
        auth = { 'HTTP_AUTHORIZATION' => "Bearer #{token}" }

        first_status, first_body   = mcp_call(otto, id: 1, headers: auth)
        second_status, second_body = mcp_call(otto, id: 2, headers: auth)

        expect([first_status, second_status]).to eq([200, 200])
        expect(first_body['result']).to include('tools')
        expect(second_body['id']).to eq(2)
      end

      it 'still rejects a request without a token' do
        status, body = mcp_call(otto, id: 3)

        expect(status).to eq(401)
        expect(body.dig('error', 'message')).to eq('Unauthorized')
      end
    end

    context 'with MCP rate limiting enabled' do
      let(:otto) do
        require_rate_limiting!
        build_frozen_otto(mcp_auth_tokens: [token], mcp_rate_limiting: true)
      end

      it 'mounts both middleware that receive the security config' do
        expect(otto.middleware_stack).to include(Otto::MCP::Auth::TokenMiddleware, Otto::MCP::RateLimitMiddleware)
      end

      it_behaves_like 'a frozen MCP app that keeps serving'
    end

    context 'with MCP rate limiting disabled' do
      let(:otto) { build_frozen_otto(mcp_auth_tokens: [token], mcp_rate_limiting: false) }

      it 'mounts the token middleware without the rate limit middleware' do
        expect(otto.middleware_stack).to include(Otto::MCP::Auth::TokenMiddleware)
        expect(otto.middleware_stack).not_to include(Otto::MCP::RateLimitMiddleware)
      end

      it_behaves_like 'a frozen MCP app that keeps serving'
    end

    context 'with MCP rate limiting enabled and no tokens' do
      let(:otto) do
        require_rate_limiting!
        build_frozen_otto(mcp_allow_unauthenticated: true, mcp_rate_limiting: true)
      end

      it 'answers repeated unauthenticated requests' do
        first_status, = mcp_call(otto, id: 1)
        second_status, = mcp_call(otto, id: 2)

        expect([first_status, second_status]).to eq([200, 200])
      end
    end
  end
end
