# spec/otto/mcp/auth/bearer_auth_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::Auth::BearerAuth do
  let(:resource_uri) { 'https://mcp.example.com/mcp' }
  let(:seen)         { [] }
  let(:context)      { Otto::MCP::Auth::Context.new(subject: 'cust_1', audience: resource_uri) }
  let(:verifier) do
    lambda { |token, env|
      seen << [token, env]
      context if token == 'good-token'
    }
  end

  def env_with(authorization = nil, extra = {})
    env = mock_rack_env(method: 'POST', path: '/mcp')
    env['HTTP_AUTHORIZATION'] = authorization if authorization
    env.merge(extra)
  end

  describe '#authenticate' do
    subject(:auth) { described_class.new(verifier, resource_uri: resource_uri) }

    it 'returns the context the verifier produced for the token' do
      env = env_with('Bearer good-token')

      expect(auth.authenticate(env)).to be(context)
      expect(seen).to eq([['good-token', env]])
    end

    it 'returns nil when the verifier rejects the token' do
      expect(auth.authenticate(env_with('Bearer other-token'))).to be_nil
    end

    it 'matches the scheme without regard to case' do
      expect(auth.authenticate(env_with('bearer good-token'))).to be(context)
      expect(auth.authenticate(env_with('BEARER   good-token'))).to be(context)
    end

    {
      'no Authorization header' => nil,
      'another scheme' => 'Basic Z29vZC10b2tlbg==',
      'a scheme with no token' => 'Bearer',
      'two tokens' => 'Bearer good-token extra',
      'characters outside b64token' => 'Bearer good"token',
      'a token longer than the limit' => "Bearer #{'a' * (described_class::MAX_TOKEN_BYTES + 1)}",
    }.each do |label, header|
      it "does not call the verifier for #{label}" do
        expect(auth.authenticate(env_with(header))).to be_nil
        expect(seen).to be_empty
      end
    end

    it 'accepts a token of exactly the limit' do
      longest = 'a' * described_class::MAX_TOKEN_BYTES
      auth    = described_class.new(->(token, _env) { context if token == longest }, resource_uri: resource_uri)

      expect(auth.authenticate(env_with("Bearer #{longest}"))).to be(context)
    end

    it 'reads no other header and no query parameter' do
      env = Rack::MockRequest.env_for('/mcp?access_token=good-token', method: 'POST')
      env['HTTP_X_MCP_TOKEN'] = 'good-token'

      expect(auth.authenticate(env)).to be_nil
      expect(seen).to be_empty
    end

    it 'rejects a context whose audience does not name this endpoint' do
      elsewhere = Otto::MCP::Auth::Context.new(subject: 'cust_1', client_id: 'client_a', audience: 'https://api.example.com')
      logged    = []
      allow(Otto.logger).to receive(:warn) { |line| logged << line }

      auth = described_class.new(->(_token, _env) { elsewhere }, resource_uri: resource_uri)

      expect(auth.authenticate(env_with('Bearer good-token'))).to be_nil
      expect(logged.join).to include('MCP token not issued for this endpoint', 'client_a')
      expect(logged.join).not_to include('good-token')
    end

    it 'does not check the audience when the endpoint has no resource URI' do
      anywhere = Otto::MCP::Auth::Context.new(subject: 'cust_1')
      auth     = described_class.new(->(_token, _env) { anywhere })

      expect(auth.authenticate(env_with('Bearer good-token'))).to be(anywhere)
    end

    [true, 'cust_1', { subject: 'cust_1' }, 1].each do |wrong|
      it "raises when the verifier returns #{wrong.class} instead of a context" do
        auth = described_class.new(->(_token, _env) { wrong }, resource_uri: resource_uri)

        expect { auth.authenticate(env_with('Bearer good-token')) }
          .to raise_error(TypeError, /must return an Otto::MCP::Auth::Context or nil/)
      end
    end

    # An authenticator works with the token, and its exceptions can quote it.
    it 'raises in place of a verifier failure, with its class and backtrace and without its message' do
      verifier = ->(token, _env) { raise IOError, "token store down while checking #{token}" }
      auth     = described_class.new(verifier, resource_uri: resource_uri)

      expect { auth.authenticate(env_with('Bearer good-token')) }.to raise_error(Otto::MCP::AuthenticatorError) { |error|
        expect(error.message).to eq('MCP authenticator raised IOError')
        expect(error.full_message(highlight: false, order: :top).lines.first).not_to include('good-token')
        expect(error.cause).to be_a(IOError)
        expect(error.backtrace.first).to include('bearer_auth_spec.rb')
      }
    end

    it 'treats a header with bytes that are invalid in its encoding as malformed' do
      header = (+"Bearer good\xFFtoken").force_encoding(Encoding::UTF_8)

      expect(auth.authenticate(env_with(header))).to be_nil
      expect(auth.challenge(env_with(header))).to include('error="invalid_token"')
      expect(seen).to be_empty
    end

    it 'hands the verifier a UTF-8 token whatever encoding the server tagged the header with' do
      auth.authenticate(env_with('Bearer good-token'.b))

      expect(seen.first.first).to eq('good-token')
      expect(seen.first.first.encoding).to eq(Encoding::UTF_8)
    end
  end

  describe '#challenge' do
    subject(:auth) { described_class.new(verifier, resource_uri: resource_uri, challenge_scopes: %w[handoff:read]) }

    let(:metadata_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

    it 'names the metadata document and the scopes, with no error, when no token was sent' do
      expect(auth.challenge(env_with)).to eq(%(Bearer scope="handoff:read", resource_metadata="#{metadata_url}"))
    end

    it 'adds invalid_token when a bearer credential was sent' do
      expect(auth.challenge(env_with('Bearer nope')))
        .to eq(%(Bearer error="invalid_token", scope="handoff:read", resource_metadata="#{metadata_url}"))
    end

    it 'does not report invalid_token for another scheme' do
      expect(auth.challenge(env_with('Basic abc'))).not_to include('error=')
    end

    it 'names the scopes it is given for insufficient_scope' do
      expect(auth.challenge(error: 'insufficient_scope', scopes: %w[handoff:write admin]))
        .to eq(%(Bearer error="insufficient_scope", scope="handoff:write admin", resource_metadata="#{metadata_url}"))
    end

    it 'never echoes the Authorization header' do
      expect(auth.challenge(env_with('Bearer sup3r-s3cret'))).not_to include('sup3r-s3cret')
    end

    it 'is the bare scheme when there is nothing to name' do
      expect(described_class.new(verifier).challenge(env_with)).to eq('Bearer')
    end
  end
end
