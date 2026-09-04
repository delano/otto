# frozen_string_literal: true

require 'digest'

require_relative '../../../../spec_helper'

RSpec.describe Otto::Security::Authentication::Strategies::APIKeyStrategy do
  def env_with_header(value, header: 'HTTP_X_API_KEY')
    { header => value }
  end

  def env_with_param(query, param: 'api_key')
    Rack::MockRequest.env_for("/?#{param}=#{query}")
  end

  describe '#initialize' do
    it 'requires the api_keys keyword' do
      expect { described_class.new }.to raise_error(ArgumentError)
    end

    it 'rejects an empty array' do
      expect { described_class.new(api_keys: []) }
        .to raise_error(ArgumentError, /at least one non-empty API key/)
    end

    it 'rejects nil' do
      expect { described_class.new(api_keys: nil) }
        .to raise_error(ArgumentError, /at least one non-empty API key/)
    end

    it 'rejects an array of only empty strings' do
      expect { described_class.new(api_keys: ['']) }
        .to raise_error(ArgumentError, /at least one non-empty API key/)
    end

    it 'rejects an array of only blank and nil values' do
      expect { described_class.new(api_keys: ['', nil]) }
        .to raise_error(ArgumentError, /at least one non-empty API key/)
    end
  end

  describe '#authenticate' do
    subject(:strategy) { described_class.new(api_keys: %w[key-one key-two key-three]) }

    it 'authenticates a correct API key from the header' do
      result = strategy.authenticate(env_with_header('key-two'), nil)
      expect(result.authenticated?).to be(true)
      expect(result.user[:api_key_fingerprint]).to eq(Digest::SHA256.hexdigest('key-two')[0, 12])
      expect(result.auth_method).to eq('api_key')
    end

    it 'does not expose the raw key in the result' do
      result = strategy.authenticate(env_with_header('key-two'), nil)
      expect(result.user).not_to have_key(:api_key)
      expect(result.metadata).not_to have_key(:api_key)
      expect(result.to_h.inspect).not_to include('key-two')
    end

    it 'ignores the query parameter by default' do
      result = strategy.authenticate(env_with_param('key-one'), nil)
      expect(result.authenticated?).to be(false)
      expect(result.failure_reason).to eq('No API key provided')
    end

    it 'authenticates a correct API key from the query parameter when opted in' do
      opted_in = described_class.new(api_keys: %w[key-one], param_name: 'api_key')
      result = opted_in.authenticate(env_with_param('key-one'), nil)
      expect(result.authenticated?).to be(true)
      expect(result.user[:api_key_fingerprint]).to eq(Digest::SHA256.hexdigest('key-one')[0, 12])
    end

    it 'authenticates the first configured key' do
      expect(strategy.authenticate(env_with_header('key-one'), nil).authenticated?).to be(true)
    end

    it 'authenticates the last configured key' do
      expect(strategy.authenticate(env_with_header('key-three'), nil).authenticated?).to be(true)
    end

    it 'supports a custom header name' do
      custom = described_class.new(api_keys: ['secret'], header_name: 'X-Otto-Token')
      result = custom.authenticate(env_with_header('secret', header: 'HTTP_X_OTTO_TOKEN'), nil)
      expect(result.authenticated?).to be(true)
    end

    it 'supports a custom param name' do
      custom = described_class.new(api_keys: ['secret'], param_name: 'token')
      result = custom.authenticate(env_with_param('secret', param: 'token'), nil)
      expect(result.authenticated?).to be(true)
    end

    it 'rejects a request with no API key, non-terminally' do
      result = strategy.authenticate({}, nil)
      expect(result.authenticated?).to be(false)
      expect(result.terminal?).to be(false)
      expect(result.failure_reason).to eq('No API key provided')
    end

    it 'rejects an empty-string header credential' do
      result = strategy.authenticate(env_with_header(''), nil)
      expect(result.authenticated?).to be(false)
      expect(result.failure_reason).to eq('No API key provided')
    end

    it 'rejects an array-valued credential terminally instead of raising' do
      opted_in = described_class.new(api_keys: %w[key-one], param_name: 'api_key')
      env = Rack::MockRequest.env_for('/?api_key[]=key-one')
      result = opted_in.authenticate(env, nil)
      expect(result.authenticated?).to be(false)
      expect(result.terminal?).to be(true)
      expect(result.failure_reason).to eq('Invalid API key')
    end

    it 'rejects a hash-valued credential terminally instead of raising' do
      opted_in = described_class.new(api_keys: %w[key-one], param_name: 'api_key')
      env = Rack::MockRequest.env_for('/?api_key[k]=key-one')
      result = opted_in.authenticate(env, nil)
      expect(result.authenticated?).to be(false)
      expect(result.terminal?).to be(true)
    end

    it 'rejects an incorrect API key terminally' do
      result = strategy.authenticate(env_with_header('wrong-key'), nil)
      expect(result.authenticated?).to be(false)
      expect(result.terminal?).to be(true)
      expect(result.failure_reason).to eq('Invalid API key')
    end

    it 'compares against every configured key even when the first matches' do
      # Message expectation (not have_received) is the point: assert the call
      # count happens during authenticate, proving no short-circuit.
      # rubocop:disable-next RSpec/MessageSpies
      expect(Rack::Utils).to receive(:secure_compare).exactly(3).times.and_call_original
      expect(strategy.authenticate(env_with_header('key-one'), nil).authenticated?).to be(true)
    end
  end
end
