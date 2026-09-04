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

  describe '.digest' do
    it 'returns the full SHA-256 hex digest of the key' do
      expect(described_class.digest('key-one')).to eq(Digest::SHA256.hexdigest('key-one'))
      expect(described_class.digest('key-one').length).to eq(64)
    end

    it 'prefixes the fingerprint placed in results' do
      result = described_class.new(api_keys: ['key-one']).authenticate(env_with_header('key-one'), nil)
      expect(described_class.digest('key-one')).to start_with(result.metadata[:api_key_fingerprint])
    end
  end

  describe 'resolver form' do
    let(:account) { { id: 42, name: 'acme' } }
    let(:presented) { 'sk_live_resolver_key' }
    let(:lookup_error) { Class.new(StandardError) }

    describe 'construction' do
      it 'rejects a resolver: that does not respond to #call' do
        expect { described_class.new(resolver: 'not callable') }
          .to raise_error(ArgumentError, /must respond to #call/)
      end

      it 'rejects api_keys: combined with a block' do
        expect { described_class.new(api_keys: ['k']) { |_key| account } }
          .to raise_error(ArgumentError, /not more than one/)
      end

      it 'rejects api_keys: combined with resolver:' do
        expect { described_class.new(api_keys: ['k'], resolver: ->(_key) { account }) }
          .to raise_error(ArgumentError, /not more than one/)
      end

      it 'rejects resolver: combined with a block' do
        expect { described_class.new(resolver: ->(_key) { account }) { |_key| account } }
          .to raise_error(ArgumentError, /not more than one/)
      end

      it 'rejects the absence of any key source' do
        expect { described_class.new }
          .to raise_error(ArgumentError, /requires a key source/)
      end
    end

    describe 'block resolver' do
      subject(:strategy) { described_class.new { |key| key == presented ? account : nil } }

      it 'returns the block value as the user with a 12-char fingerprint in metadata' do
        result = strategy.authenticate(env_with_header(presented), nil)
        expect(result.authenticated?).to be(true)
        expect(result.user).to eq(account)
        expect(result.auth_method).to eq('api_key')
        expect(result.metadata[:api_key_fingerprint]).to eq(Digest::SHA256.hexdigest(presented)[0, 12])
        expect(result.metadata[:api_key_fingerprint].length).to eq(12)
      end

      it 'passes exactly the presented String key to the block' do
        received = []
        capturing = described_class.new do |*args|
          received << args
          account
        end
        capturing.authenticate(env_with_header(presented), nil)
        expect(received).to eq([[presented]])
        expect(received.first.first).to be_a(String)
      end

      it 'fails terminally when the block returns nil' do
        result = strategy.authenticate(env_with_header('unknown-key'), nil)
        expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
        expect(result.authenticated?).to be(false)
        expect(result.terminal?).to be(true)
        expect(result.failure_reason).to eq('Invalid API key')
      end

      it 'fails terminally when the block returns false' do
        falsy = described_class.new { |_key| false }
        result = falsy.authenticate(env_with_header(presented), nil)
        expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
        expect(result.terminal?).to be(true)
        expect(result.failure_reason).to eq('Invalid API key')
      end

      it 'treats any non-nil, non-false return as a match, including empty containers' do
        # Pins the truthy contract: a resolver built on `where`/`select` or a
        # cache returning {} on miss authenticates every key. Return nil on miss.
        [[], {}, '', 0].each do |value|
          permissive = described_class.new { |_key| value }
          result = permissive.authenticate(env_with_header(presented), nil)
          expect(result.authenticated?).to be(true), "expected #{value.inspect} to authenticate"
          expect(result.user).to eq(value)
        end
      end

      it 'propagates exceptions raised by the resolver' do
        error_class = lookup_error
        raising = described_class.new { |_key| raise error_class, 'db down' }
        expect { raising.authenticate(env_with_header(presented), nil) }
          .to raise_error(error_class, 'db down')
      end

      it 'does not call the block for a blank header and fails non-terminally' do
        called = false
        strict = described_class.new do |_key|
          called = true
          account
        end
        result = strict.authenticate(env_with_header(''), nil)
        expect(called).to be(false)
        expect(result.authenticated?).to be(false)
        expect(result.terminal?).to be(false)
        expect(result.failure_reason).to eq('No API key provided')
      end

      it 'does not call the block for a missing header' do
        called = false
        strict = described_class.new do |_key|
          called = true
          account
        end
        result = strict.authenticate({}, nil)
        expect(called).to be(false)
        expect(result.failure_reason).to eq('No API key provided')
      end

      it 'does not call the block for an array-valued query parameter and fails terminally' do
        called = false
        opted_in = described_class.new(param_name: 'api_key') do |_key|
          called = true
          account
        end
        env = Rack::MockRequest.env_for("/?api_key[]=#{presented}")
        result = opted_in.authenticate(env, nil)
        expect(called).to be(false)
        expect(result.authenticated?).to be(false)
        expect(result.terminal?).to be(true)
        expect(result.failure_reason).to eq('Invalid API key')
      end

      it 'does not expose the raw key in the result' do
        result = strategy.authenticate(env_with_header(presented), nil)
        expect(result.user.inspect).not_to include(presented)
        expect(result.metadata.inspect).not_to include(presented)
        expect(result.metadata).not_to have_key(:api_key)
        expect(result.to_h.inspect).not_to include(presented)
        expect(result.inspect).not_to include(presented)
      end

      it 'ignores the query parameter by default' do
        result = strategy.authenticate(env_with_param(presented), nil)
        expect(result.authenticated?).to be(false)
        expect(result.failure_reason).to eq('No API key provided')
      end

      it 'reads the query parameter when opted in' do
        opted_in = described_class.new(param_name: 'api_key') { |key| key == presented ? account : nil }
        result = opted_in.authenticate(env_with_param(presented), nil)
        expect(result.authenticated?).to be(true)
        expect(result.user).to eq(account)
      end

      it 'supports a custom header name' do
        custom = described_class.new(header_name: 'X-Otto-Token') { |key| key == presented ? account : nil }
        result = custom.authenticate(env_with_header(presented, header: 'HTTP_X_OTTO_TOKEN'), nil)
        expect(result.authenticated?).to be(true)
      end
    end

    describe 'callable resolver' do
      let(:repo) do
        Class.new do
          def initialize(account)
            @account = account
          end

          def find_by_key(key)
            key == 'sk_live_resolver_key' ? @account : nil
          end
        end.new(account)
      end

      it 'accepts a Method object' do
        strategy = described_class.new(resolver: repo.method(:find_by_key))
        result = strategy.authenticate(env_with_header(presented), nil)
        expect(result.authenticated?).to be(true)
        expect(result.user).to eq(account)
        expect(result.metadata[:api_key_fingerprint]).to eq(Digest::SHA256.hexdigest(presented)[0, 12])
      end

      it 'accepts a lambda' do
        strategy = described_class.new(resolver: ->(key) { key == presented ? account : nil })
        expect(strategy.authenticate(env_with_header(presented), nil).user).to eq(account)
        expect(strategy.authenticate(env_with_header('nope'), nil).terminal?).to be(true)
      end

      it 'propagates exceptions raised by the callable' do
        error_class = lookup_error
        strategy = described_class.new(resolver: ->(_key) { raise error_class })
        expect { strategy.authenticate(env_with_header(presented), nil) }.to raise_error(error_class)
      end
    end
  end
end
