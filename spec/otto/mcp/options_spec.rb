# spec/otto/mcp/options_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::Options do
  let(:defaults) do
    {
              http_endpoint: '/_mcp',
                auth_tokens: [],
          enable_validation: true,
       enable_rate_limiting: true,
        requests_per_minute: 60,
           tools_per_minute: 20,
      allow_unauthenticated: false,
    }
  end

  # .normalize takes a `scope:` keyword, so a brace-less hash literal at the
  # call site is parsed as keywords ("unknown keyword: :auth_tokens"). This
  # helper keeps the examples readable by passing a positional Hash.
  def norm(opts)
    described_class.normalize(opts)
  end

  describe '.normalize' do
    it 'returns the canonical defaults for an empty hash' do
      expect(described_class.normalize({})).to eq(defaults)
    end

    it 'defaults when called with no arguments' do
      expect(described_class.normalize).to eq(defaults)
    end

    it 'defaults to the strict :explicit scope' do
      expect { norm(auth_token: 'typo') }
        .to raise_error(ArgumentError, /Unknown MCP option\(s\): :auth_token/)
    end

    it 'rejects an unknown scope' do
      expect { described_class.normalize({}, scope: :nonsense) }
        .to raise_error(ArgumentError, /Unknown MCP option scope :nonsense/)
    end
  end

  # The two vocabularies. :explicit is what #enable_mcp! speaks; :constructor is
  # what Otto.new speaks, and it must not claim generic keys out of an options
  # hash that also configures the rest of Otto.
  describe 'the :explicit scope (#enable_mcp!)' do
    def normalize(opts)
      described_class.normalize(opts, scope: :explicit)
    end

    describe 'aliases' do
      {
                http_endpoint: [%i[http_endpoint mcp_endpoint endpoint], '/api/mcp'],
                  auth_tokens: [%i[auth_tokens mcp_auth_tokens], ['tok']],
            enable_validation: [%i[enable_validation validation mcp_validation], false],
         enable_rate_limiting: [%i[enable_rate_limiting rate_limiting mcp_rate_limiting], false],
          requests_per_minute: [%i[requests_per_minute mcp_requests_per_minute], 5],
             tools_per_minute: [%i[tools_per_minute tool_calls_per_minute mcp_tool_calls_per_minute], 2],
        allow_unauthenticated: [%i[allow_unauthenticated mcp_allow_unauthenticated], true],
      }.each do |canonical, (aliases, value)|
        aliases.each do |alias_key|
          it "maps #{alias_key} to #{canonical}" do
            expect(normalize(alias_key => value)).to eq(defaults.merge(canonical => value))
          end
        end
      end

      it 'declares exactly these canonical options' do
        expect(described_class::OPTION_ALIASES.keys).to match_array(defaults.keys)
      end
    end

    it 'accepts the generic bare spellings this scope owns' do
      expect(normalize(endpoint: '/api/mcp', validation: false, rate_limiting: false))
        .to eq(defaults.merge(http_endpoint: '/api/mcp', enable_validation: false,
                              enable_rate_limiting: false))
    end

    it 'keeps the rate_limiting_spec spelling working' do
      expect { normalize(rate_limiting: true, http_endpoint: '/api/mcp') }.not_to raise_error
    end

    describe 'strictness' do
      it 'raises on a singular auth_token typo rather than leaving the endpoint open' do
        expect { normalize(auth_token: 'x') }
          .to raise_error(ArgumentError, /Unknown MCP option\(s\): :auth_token/)
      end

      it 'raises on any unrecognized key, mcp_-prefixed or not' do
        expect { normalize(csrf_protection: true) }
          .to raise_error(ArgumentError, /Unknown MCP option\(s\): :csrf_protection/)
        expect { normalize(mcp_tokens: 'x') }
          .to raise_error(ArgumentError, /Unknown MCP option\(s\): :mcp_tokens/)
      end

      it 'reports every unrecognized key' do
        expect { normalize(foo: 1, mcp_bar: 2) }
          .to raise_error(ArgumentError, /:foo, :mcp_bar/)
      end

      it 'lists the recognized options in the message' do
        normalize(nope: 1)
      rescue ArgumentError => e
        expect(e.message).to include('Recognized MCP options:', ':auth_tokens', ':mcp_auth_tokens',
                                     ':endpoint', ':mcp_enabled')
      else
        raise 'expected ArgumentError'
      end

      described_class::GATING_KEYS.each do |gating_key|
        it "tolerates the gating key #{gating_key} and ignores its value" do
          expect(normalize(gating_key => true)).to eq(defaults)
        end
      end
    end
  end

  describe 'the :constructor scope (Otto.new)' do
    def normalize(opts)
      described_class.normalize(opts, scope: :constructor)
    end

    describe 'accepted spellings' do
      {
                http_endpoint: [%i[http_endpoint mcp_endpoint], '/api/mcp'],
                  auth_tokens: [%i[auth_tokens mcp_auth_tokens], ['tok']],
            enable_validation: [%i[enable_validation mcp_validation], false],
         enable_rate_limiting: [%i[enable_rate_limiting mcp_rate_limiting], false],
          requests_per_minute: [%i[requests_per_minute mcp_requests_per_minute], 5],
             tools_per_minute: [%i[tools_per_minute tool_calls_per_minute mcp_tool_calls_per_minute], 2],
        allow_unauthenticated: [%i[allow_unauthenticated mcp_allow_unauthenticated], true],
      }.each do |canonical, (aliases, value)|
        aliases.each do |alias_key|
          it "maps #{alias_key} to #{canonical}" do
            expect(normalize(alias_key => value)).to eq(defaults.merge(canonical => value))
          end
        end
      end

      it 'accepts the four documented bare keys' do
        normalized = normalize(
          auth_tokens: ['tok'],
          requests_per_minute: 5,
          tools_per_minute: 2,
          allow_unauthenticated: true
        )

        expect(normalized).to eq(defaults.merge(auth_tokens: ['tok'], requests_per_minute: 5,
                                                tools_per_minute: 2, allow_unauthenticated: true))
      end
    end

    describe 'generic keys it must not claim' do
      described_class::GENERIC_ALIASES.each do |generic|
        it "ignores bare #{generic}" do
          expect(described_class::CONSTRUCTOR_ALIASES.values.flatten).not_to include(generic)
        end
      end

      it 'ignores bare endpoint:' do
        expect(normalize(endpoint: '/somewhere/else')[:http_endpoint]).to eq('/_mcp')
      end

      it 'ignores bare validation:' do
        expect(normalize(validation: false)[:enable_validation]).to be true
      end

      it "ignores Otto's general rate_limiting: Hash instead of choking on it" do
        expect(normalize(rate_limiting: { requests_per_minute: 100 }))
          .to eq(defaults)
      end

      it 'ignores bare rate_limiting: false' do
        expect(normalize(rate_limiting: false)[:enable_rate_limiting]).to be true
      end

      it 'requires the mcp_ spelling to disable MCP rate limiting' do
        expect(normalize(mcp_rate_limiting: false)[:enable_rate_limiting]).to be false
      end
    end

    it 'ignores unrelated non-MCP options' do
      opts = { csrf_protection: true, trusted_proxies: ['127.0.0.1'], locale_config: {} }
      expect(normalize(opts)).to eq(defaults)
    end

    describe 'unknown mcp_ keys still fail loud' do
      it 'raises' do
        expect { normalize(mcp_auth_token: 'oops') }
          .to raise_error(ArgumentError, /Unknown MCP option\(s\): :mcp_auth_token/)
      end

      it 'reports every unknown mcp_ key' do
        expect { normalize(mcp_foo: 1, mcp_bar: 2) }
          .to raise_error(ArgumentError, /:mcp_foo, :mcp_bar/)
      end

      described_class::GATING_KEYS.each do |gating_key|
        it "accepts the gating key #{gating_key} and ignores its value" do
          expect(normalize(gating_key => true)).to eq(defaults)
        end
      end
    end

    it 'accepts the full constructor vocabulary in one hash' do
      normalized = normalize(
        mcp_enabled: true,
        mcp_endpoint: '/api/mcp',
        mcp_auth_tokens: 'tok',
        mcp_requests_per_minute: 5,
        tool_calls_per_minute: 2,
        mcp_allow_unauthenticated: true,
        mcp_validation: false,
        csrf_protection: true
      )

      expect(normalized).to eq(
        http_endpoint: '/api/mcp',
        auth_tokens: ['tok'],
        enable_validation: false,
        enable_rate_limiting: true,
        requests_per_minute: 5,
        tools_per_minute: 2,
        allow_unauthenticated: true
      )
    end
  end

  describe 'auth_tokens' do
    it 'wraps a String in an Array' do
      expect(norm(auth_tokens: 'solo')[:auth_tokens]).to eq(['solo'])
    end

    it 'passes an Array of Strings through' do
      expect(norm(auth_tokens: %w[a b])[:auth_tokens]).to eq(%w[a b])
    end

    it 'raises on non-String entries' do
      expect { norm(auth_tokens: [123]) }
        .to raise_error(ArgumentError, /auth_tokens must be Strings.*Integer/)
    end

    # The ENV['MCP_TOKEN']-is-unset trap: an empty token list mounts no auth
    # middleware, so silently accepting it serves the endpoint to anyone.
    describe 'supplied but empty' do
      [nil, '', '   ', [nil], [''], ['  ']].each do |empty|
        it "raises for auth_tokens: #{empty.inspect}" do
          expect { norm(auth_tokens: empty) }
            .to raise_error(ArgumentError, /auth_tokens/)
        end
      end

      it 'explains the ENV trap and both remedies' do
        norm(auth_tokens: nil)
      rescue ArgumentError => e
        expect(e.message).to include("ENV['MCP_TOKEN']", 'expose the MCP endpoint',
                                     'allow_unauthenticated: true')
      else
        raise 'expected ArgumentError'
      end

      it 'raises in the constructor scope too' do
        expect { described_class.normalize({ auth_tokens: nil }, scope: :constructor) }
          .to raise_error(ArgumentError, /resolves to no tokens/)
      end

      it 'accepts a literal empty Array, the spelling normalize itself emits' do
        expect(norm(auth_tokens: [])[:auth_tokens]).to eq([])
      end

      it 'still defaults to no tokens when the key is omitted' do
        expect(described_class.normalize({})[:auth_tokens]).to eq([])
      end
    end

    describe 'blank tokens' do
      it 'raises when a token is empty' do
        expect { norm(auth_tokens: ['good', '']) }
          .to raise_error(ArgumentError, /must not be blank/)
      end

      it 'raises when a token is whitespace only' do
        expect { norm(auth_tokens: ['good', "\t \n"]) }
          .to raise_error(ArgumentError, /must not be blank/)
      end

      it 'names the offending token' do
        expect { norm(auth_tokens: ['good', ' ']) }
          .to raise_error(ArgumentError, /" "/)
      end
    end
  end

  describe 'value validation' do
    it 'rejects a non-boolean rate limiting flag' do
      expect { norm(rate_limiting: 'yes') }
        .to raise_error(ArgumentError, /enable_rate_limiting must be true or false/)
    end

    it 'rejects a Hash rate limiting flag in the explicit scope' do
      expect { norm(rate_limiting: { requests_per_minute: 10 }) }
        .to raise_error(ArgumentError, /enable_rate_limiting must be true or false/)
    end

    it 'rejects a non-boolean validation flag' do
      expect { norm(validation: 'yes') }
        .to raise_error(ArgumentError, /enable_validation must be true or false/)
    end

    it 'rejects a non-boolean allow_unauthenticated' do
      expect { norm(allow_unauthenticated: 'yes') }
        .to raise_error(ArgumentError, /allow_unauthenticated must be true or false/)
    end

    [0, -1, 'ten', 1.5, nil].each do |bad|
      it "rejects requests_per_minute: #{bad.inspect}" do
        expect { norm(requests_per_minute: bad) }
          .to raise_error(ArgumentError, /requests_per_minute must be a positive Integer/)
      end

      it "rejects tools_per_minute: #{bad.inspect}" do
        expect { norm(tools_per_minute: bad) }
          .to raise_error(ArgumentError, /tools_per_minute must be a positive Integer/)
      end
    end

    ['_mcp', 'https://example.com/_mcp', '', :_mcp, nil].each do |bad|
      it "rejects http_endpoint: #{bad.inspect}" do
        expect { norm(http_endpoint: bad) }
          .to raise_error(ArgumentError, %r{http_endpoint must be a String path starting with '/'})
      end
    end
  end

  describe 'conflicting aliases' do
    it 'raises when two aliases disagree' do
      expect { norm(endpoint: '/a', mcp_endpoint: '/b') }
        .to raise_error(ArgumentError, /Conflicting MCP options for http_endpoint/)
    end

    it 'names both offending keys and values' do
      expect { norm(auth_tokens: ['a'], mcp_auth_tokens: ['b']) }
        .to raise_error(ArgumentError, /auth_tokens=\["a"\].*mcp_auth_tokens=\["b"\]/)
    end

    it 'accepts two aliases that agree' do
      expect(norm(endpoint: '/a', mcp_endpoint: '/a')[:http_endpoint]).to eq('/a')
    end

    it 'does not see a conflict for an alias the constructor scope ignores' do
      expect(described_class.normalize({ endpoint: '/a', mcp_endpoint: '/b' }, scope: :constructor)[:http_endpoint])
        .to eq('/b')
    end
  end

  describe 'idempotence' do
    %i[constructor explicit].each do |scope|
      it "re-normalizes its own output unchanged under the #{scope} scope" do
        once = described_class.normalize(
          { mcp_endpoint: '/api/mcp', mcp_auth_tokens: 'tok', tool_calls_per_minute: 2 },
          scope: scope
        )

        expect(described_class.normalize(once, scope: scope)).to eq(once)
      end

      it "re-normalizes the bare defaults unchanged under the #{scope} scope" do
        once = described_class.normalize({}, scope: scope)

        expect(described_class.normalize(once, scope: scope)).to eq(once)
      end
    end
  end

  it 'does not mutate the input hash' do
    opts = { mcp_enabled: true, auth_tokens: 'tok' }
    expect { described_class.normalize(opts) }
      .not_to(change { opts.dup })
  end

  describe 'Otto::MCP::Server.normalize_options' do
    it 'delegates to the normalizer' do
      expect(Otto::MCP::Server.normalize_options({ mcp_endpoint: '/api/mcp' }))
        .to eq(norm(mcp_endpoint: '/api/mcp'))
    end

    it 'defaults to the explicit scope' do
      expect { Otto::MCP::Server.normalize_options({ csrf_protection: true }) }
        .to raise_error(ArgumentError, /Unknown MCP option/)
    end

    it 'forwards the scope keyword' do
      expect(Otto::MCP::Server.normalize_options({ csrf_protection: true }, scope: :constructor))
        .to eq(defaults)
    end
  end
end
