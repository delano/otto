# frozen_string_literal: true

require_relative '../../../../spec_helper'

RSpec.describe Otto::Security::Authentication::Strategies::APIKeyStrategy do
  def env_with_header(value)
    { 'HTTP_X_API_KEY' => value }
  end

  describe '#authenticate' do
    context 'with configured API keys' do
      subject(:strategy) { described_class.new(api_keys: %w[key-one key-two]) }

      it 'authenticates a correct API key' do
        result = strategy.authenticate(env_with_header('key-two'), nil)
        expect(result.authenticated?).to be(true)
        expect(result.user[:api_key]).to eq('key-two')
      end

      it 'rejects an incorrect API key' do
        result = strategy.authenticate(env_with_header('wrong-key'), nil)
        expect(result.authenticated?).to be(false)
      end

      it 'rejects a request with no API key' do
        result = strategy.authenticate({}, nil)
        expect(result.authenticated?).to be(false)
      end
    end

    context 'with no API keys configured' do
      subject(:strategy) { described_class.new(api_keys: []) }

      it 'accepts any provided API key' do
        result = strategy.authenticate(env_with_header('anything-goes'), nil)
        expect(result.authenticated?).to be(true)
        expect(result.user[:api_key]).to eq('anything-goes')
      end
    end
  end
end
