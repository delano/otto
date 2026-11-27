# spec/otto/mcp/option_rules_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# The options that select protocol revisions, the authenticator and the
# hosted profile. spec/otto/mcp/options_spec.rb covers the options that
# predate them, and pins the canonical hash those produce.
RSpec.describe Otto::MCP::OptionRules do
  let(:authenticator) { ->(_token, _env) {} }
  let(:hosted) do
    { hosted: true, authenticator: authenticator, resource_uri: 'https://mcp.example.com/mcp',
      authorization_servers: ['https://auth.example.com'] }
  end

  def norm(opts, scope = :explicit)
    Otto::MCP::Options.normalize(opts, scope)
  end

  it 'emits none of them unless supplied' do
    expect(norm({}).keys & Otto::MCP::Options::EXTENDED_ALIASES.keys).to be_empty
  end

  it 'accepts every option under its mcp_ alias, in both scopes' do
    Otto::MCP::Options::EXTENDED_ALIASES.each do |canonical, (plain, prefixed)|
      expect(plain).to eq(canonical)
      expect(prefixed).to eq(:"mcp_#{canonical}")
    end

    expect(norm({ mcp_cache_ttl_ms: 5 }, :constructor)[:cache_ttl_ms]).to eq(5)
    expect(norm(mcp_cache_ttl_ms: 5)[:cache_ttl_ms]).to eq(5)
  end

  it 'refuses two spellings of one option that disagree' do
    expect { norm(cache_ttl_ms: 1, mcp_cache_ttl_ms: 2) }.to raise_error(ArgumentError, /Conflicting MCP options for cache_ttl_ms/)
  end

  it 'is idempotent for a full hosted configuration' do
    once = norm(hosted.merge(scopes_supported: %w[a], allowed_origins: ['https://App.example.com'],
                             request_state_secret: 's' * 32, server_info: { name: 'N', version: '1' },
                             instructions: 'Use it well.', cache_ttl_ms: 1000))

    %i[explicit constructor].each { |scope| expect(norm(once, scope)).to eq(once) }
  end

  describe 'http_endpoint' do
    # Otto routes ':name' and '*' as patterns, and the MCP guards compare the
    # path exactly, so a request for /acme/mcp reached an endpoint at
    # /:tenant/mcp without a token.
    ['/:tenant/mcp', '/mcp/*', '/*', '/mcp/:id', '/a:b'].each do |pattern|
      it "refuses #{pattern}, which the router would match as a pattern" do
        expect { norm(http_endpoint: pattern) }
          .to raise_error(ArgumentError, /http_endpoint must be a literal path without ':name' segments or '\*'/)
        expect { norm({ mcp_endpoint: pattern }, :constructor) }.to raise_error(ArgumentError, /literal path/)
      end
    end

    ['/_mcp', '/api/v2/mcp', '/mcp.json', '/a-b_c/mcp', '/', '/mcp/'].each do |literal|
      it "accepts #{literal}" do
        expect(norm(http_endpoint: literal)[:http_endpoint]).to eq(literal)
      end
    end
  end

  describe 'protocol_versions' do
    it 'accepts a String or an Array and orders newest first' do
      expect(norm(protocol_versions: '2026-07-28')[:protocol_versions]).to eq(%w[2026-07-28])
      expect(norm(protocol_versions: %w[2024-11-05 2026-07-28 2024-11-05])[:protocol_versions]).to eq(%w[2026-07-28 2024-11-05])
    end

    it 'names the supported revisions when one is not' do
      expect { norm(protocol_versions: %w[2025-11-25]) }
        .to raise_error(ArgumentError, /"2025-11-25" not supported\. Supported: 2026-07-28, 2024-11-05/)
    end

    [[], [nil], 20_260_728].each do |invalid|
      it "refuses #{invalid.inspect}" do
        expect { norm(protocol_versions: invalid) }.to raise_error(ArgumentError, /protocol_versions must be/)
      end
    end
  end

  describe 'authenticator' do
    it 'accepts anything that responds to #call' do
      expect(norm(authenticator: authenticator)[:authenticator]).to be(authenticator)
      expect(norm(authenticator: authenticator.method(:call))[:authenticator]).to respond_to(:call)
    end

    it 'refuses an object that cannot be called' do
      expect { norm(authenticator: 'MyVerifier') }.to raise_error(ArgumentError, /must respond to #call\(token, env\)/)
    end

    it 'refuses to be combined with static tokens' do
      expect { norm(authenticator: authenticator, auth_tokens: ['t']) }
        .to raise_error(ArgumentError, /authenticator and auth_tokens cannot both be set/)
    end

    it 'refuses to be combined with allow_unauthenticated' do
      expect { norm(authenticator: authenticator, allow_unauthenticated: true) }
        .to raise_error(ArgumentError, /contradict each other/)
    end
  end

  describe 'a supplied nil' do
    Otto::MCP::Options::EXTENDED_ALIASES.each_key do |option|
      it "is refused for #{option}, so a failed lookup cannot unset a protection" do
        expect { norm(option => nil) }.to raise_error(ArgumentError, /#{option} was supplied as nil/)
      end
    end
  end

  describe 'resource_uri and authorization_servers' do
    it 'must be set together' do
      expect { norm(authenticator: authenticator, resource_uri: 'https://mcp.example.com/mcp') }
        .to raise_error(ArgumentError, /Set both or neither/)
      expect { norm(authenticator: authenticator, authorization_servers: ['https://auth.example.com']) }
        .to raise_error(ArgumentError, /Set both or neither/)
    end

    it 'need an authenticator' do
      expect { norm(resource_uri: 'https://mcp.example.com/mcp', authorization_servers: ['https://auth.example.com']) }
        .to raise_error(ArgumentError, /resource_uri apply to an authenticator/)
      expect { norm(scopes_supported: %w[a]) }.to raise_error(ArgumentError, /scopes_supported apply to an authenticator/)
    end

    ['mcp.example.com', 'ftp://mcp.example.com', 'https://mcp.example.com/mcp#frag', '/mcp', 'https://', 42, 'not a uri'].each do |invalid|
      it "refuses #{invalid.inspect} as a resource URI" do
        expect { norm(hosted.merge(resource_uri: invalid)) }
          .to raise_error(ArgumentError, /resource_uri must be an absolute http or https URI without a fragment/)
      end
    end

    it 'refuses an empty or malformed list of authorization servers' do
      expect { norm(hosted.merge(authorization_servers: [])) }.to raise_error(ArgumentError, /authorization_servers must be/)
      expect { norm(hosted.merge(authorization_servers: ['auth.example.com'])) }
        .to raise_error(ArgumentError, /authorization_servers must be an absolute/)
    end
  end

  describe 'hosted' do
    it 'serves 2026-07-28 unless told otherwise' do
      expect(norm(hosted)[:protocol_versions]).to eq(%w[2026-07-28])
    end

    it 'refuses a revision that opens with initialize' do
      expect { norm(hosted.merge(protocol_versions: %w[2026-07-28 2024-11-05])) }
        .to raise_error(ArgumentError, /hosted: true serves 2026-07-28 only, got protocol_versions 2024-11-05/)
    end

    it 'names everything that is missing' do
      expect { norm(hosted: true) }
        .to raise_error(ArgumentError, 'MCP hosted: true requires authenticator, resource_uri, authorization_servers')
    end

    it 'refuses static tokens and an acknowledged open endpoint' do
      expect { norm(hosted.merge(auth_tokens: ['t'])) }.to raise_error(ArgumentError, /cannot both be set/)
      expect { norm(hosted.merge(allow_unauthenticated: true)) }.to raise_error(ArgumentError, /contradict/)
    end

    it 'must be exactly true or false' do
      expect { norm(hosted: 'true') }.to raise_error(ArgumentError, /hosted must be true or false/)
    end
  end

  describe 'allowed_origins' do
    it 'normalizes case and accepts a single String' do
      expect(norm(allowed_origins: 'HTTPS://App.Example.com')[:allowed_origins]).to eq(['https://app.example.com'])
    end

    it 'accepts an empty list, which admits no browser origin' do
      expect(norm(allowed_origins: [])[:allowed_origins]).to eq([])
    end

    ['https://app.example.com/', 'https://app.example.com/path', 'app.example.com', '*', 'https://app.example.com?x=1', 7].each do |invalid|
      it "refuses #{invalid.inspect}" do
        expect { norm(allowed_origins: [invalid]) }.to raise_error(ArgumentError, %r{scheme://host\[:port\]})
      end
    end
  end

  describe 'request_state_secret' do
    it 'needs at least 32 bytes and does not print what it was given' do
      expect { norm(request_state_secret: 'too-short-to-use') }
        .to raise_error(ArgumentError) { |error| expect(error.message).not_to include('too-short-to-use') }
      expect(norm(request_state_secret: 's' * 32)[:request_state_secret]).to eq('s' * 32)
    end

    it 'is not printed when two spellings of it disagree' do
      first  = 'first-secret-0123456789abcdefghijkl'
      second = 'second-secret-0123456789abcdefghijk'

      [{ request_state_secret: first, mcp_request_state_secret: second },
       { request_state_secret: first, 'request_state_secret' => second }].each do |opts|
        expect { norm(opts) }.to raise_error(ArgumentError) { |error|
          expect(error.message).to include('Conflicting MCP options', '[REDACTED]')
          expect(error.message).not_to include(first, second)
        }
      end
    end

    it 'is redacted in the options Otto keeps' do
      otto = Otto.new(nil, mcp_request_state_secret: 's3cr3t' * 8)

      expect(otto.option.inspect).not_to include('s3cr3t')
    end
  end

  describe 'server_info, instructions and cache_ttl_ms' do
    it 'accepts Symbol or String keys for server_info' do
      expect(norm(server_info: { name: 'Onetime Secret', 'version' => '1.2.3', title: 'Secrets' })[:server_info])
        .to eq('name' => 'Onetime Secret', 'version' => '1.2.3', 'title' => 'Secrets')
    end

    [{}, { name: 'N' }, { name: 'N', version: 1 }, { name: ' ', version: '1' }, { name: 'N', version: '1', url: 'x' }, 'N 1'].each do |invalid|
      it "refuses #{invalid.inspect} as server_info" do
        expect { norm(server_info: invalid) }.to raise_error(ArgumentError, /server_info must be a Hash/)
      end
    end

    it 'refuses blank instructions and a negative or fractional ttl' do
      expect { norm(instructions: ' ') }.to raise_error(ArgumentError, /instructions must be a non-blank String/)
      expect { norm(cache_ttl_ms: -1) }.to raise_error(ArgumentError, /cache_ttl_ms must be an Integer of 0 or more/)
      expect { norm(cache_ttl_ms: 1.5) }.to raise_error(ArgumentError, /cache_ttl_ms must be an Integer of 0 or more/)
    end
  end
end
