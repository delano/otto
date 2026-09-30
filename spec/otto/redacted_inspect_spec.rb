# spec/otto/redacted_inspect_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Objects that hold secrets must not print them from #inspect. Ruby's native
# FrozenError message embeds the receiver's #inspect, and Otto's error handler
# logs error.message, so a write to a frozen config would otherwise put the
# secret in the log. Integration spec over several classes, not one.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'Secrets in #inspect output' do
  let(:csrf_secret)        { 'csrf-secret-value-0123456789abcdef' }
  let(:correlation_secret) { 'correlation-secret-value-0123456789' }
  let(:mcp_token)          { 'mcp-token-value-0123456789abcdef' }

  def frozen_error_message
    yield
    raise 'expected FrozenError'
  rescue FrozenError => e
    e.message
  end

  describe Otto::Security::Config do
    let(:config) do
      cfg = described_class.new
      cfg.csrf_secret = csrf_secret
      cfg
    end

    it 'redacts a configured CSRF secret' do
      expect(config.inspect).not_to include(csrf_secret)
      expect(config.inspect).to include('@csrf_secret=[REDACTED]')
    end

    it 'redacts a generated CSRF secret' do
      generated = described_class.new
      secret    = generated.instance_variable_get(:@csrf_secret)

      expect(generated.inspect).not_to include(secret)
      expect(generated.inspect).to include('@csrf_secret=[REDACTED]')
    end

    it 'keeps the Object#inspect shape and the other settings' do
      expect(config.inspect).to match(/\A#<Otto::Security::Config:0x\h+ @/)
      expect(config.inspect).to include('@csrf_token_key="_csrf_token"')
    end

    it 'keeps the secret out of the FrozenError message from a write after deep_freeze!' do
      config.deep_freeze!
      message = frozen_error_message { config.max_request_size = 1 }

      expect(message).to start_with("can't modify frozen Otto::Security::Config")
      expect(message).not_to include(csrf_secret)
    end

    it 'redacts MCP tokens and the correlation secret reachable from the config' do
      config.mcp_auth = Otto::MCP::Auth::TokenAuth.new([mcp_token])
      config.ip_privacy_config.correlation_secret = correlation_secret

      expect(config.inspect).not_to include(mcp_token)
      expect(config.inspect).not_to include(correlation_secret)
    end

    it 'keeps the secret out of the error log for a FrozenError raised in a request' do
      otto = Otto.new(nil)
      otto.security_config.csrf_secret = csrf_secret
      otto.freeze_configuration!
      error = frozen_error_message { otto.security_config.max_request_size = 1 }
      logged = []
      allow(Otto).to receive(:structured_log) { |_level, _message, data| logged << data }

      otto.handle_error(FrozenError.new(error), mock_rack_env(method: 'GET', path: '/'))

      expect(logged).not_to be_empty
      expect(logged.inspect).not_to include(csrf_secret)
    end
  end

  describe Otto::Privacy::Config do
    it 'redacts the correlation secret and keeps an unset one visible' do
      config = described_class.new(correlation_secret: correlation_secret)

      expect(config.inspect).not_to include(correlation_secret)
      expect(config.inspect).to include('@correlation_secret=[REDACTED]')
      expect(described_class.new.inspect).to include('@correlation_secret=nil')
    end

    it 'keeps the secret out of the FrozenError message from a write after deep_freeze!' do
      config = described_class.new(correlation_secret: correlation_secret)
      config.deep_freeze!
      message = frozen_error_message { config.octet_precision = 2 }

      expect(message).to start_with("can't modify frozen Otto::Privacy::Config")
      expect(message).not_to include(correlation_secret)
    end
  end

  describe Otto::MCP::Auth::TokenAuth do
    it 'redacts the tokens and shows how many there are' do
      auth = described_class.new([mcp_token, "#{mcp_token}-2"])

      expect(auth.inspect).not_to include(mcp_token)
      expect(auth.inspect).to include('@tokens=[REDACTED] (2)')
    end
  end

  describe 'Otto with MCP bearer tokens' do
    let(:otto) do
      Otto.new(nil, mcp_enabled: true, mcp_http: true, mcp_validation: false,
                    mcp_rate_limiting: false, mcp_auth_tokens: [mcp_token])
    end

    it 'keeps the tokens out of Otto#inspect' do
      expect(otto.inspect).not_to include(mcp_token)
      # Hash#inspect prints `key: value` from Ruby 3.4 and `:key=>value` before.
      expect(otto.inspect).to match(/mcp_auth_tokens(: |=>)\[REDACTED\] \(1\)/)
    end

    it 'keeps the tokens out of the MCP server #inspect' do
      expect(otto.mcp_server.inspect).not_to include(mcp_token)
      expect(otto.mcp_server.inspect).to include('@auth_tokens=[REDACTED] (1)')
    end

    it 'prints an object reachable from itself once' do
      # Otto -> @mcp_server -> @otto_instance -> Otto
      expect(otto.inspect).to match(/#<Otto:0x\h+ \.\.\.>/)
    end

    it 'keeps the tokens out of the server and TokenAuth copies' do
      server_tokens = otto.mcp_server.instance_variable_get(:@auth_tokens)
      auth_tokens   = otto.security_config.mcp_auth.instance_variable_get(:@tokens)

      expect(server_tokens).not_to equal(otto.option[:mcp_auth_tokens])
      expect(server_tokens.inspect).not_to include(mcp_token)
      expect(auth_tokens.inspect).not_to include(mcp_token)
    end
  end

  describe 'the Otto.new debug log line' do
    around do |example|
      original = Otto.debug
      Otto.debug = true
      example.run
    ensure
      Otto.debug = original
    end

    it 'logs the options without the MCP tokens' do
      lines = []
      allow(Otto.logger).to receive(:debug) { |message = nil, &block| lines << (message || block&.call).to_s }

      Otto.new(nil, mcp_enabled: true, mcp_http: true, mcp_validation: false,
                    mcp_rate_limiting: false, mcp_auth_tokens: [mcp_token])

      new_otto = lines.grep(/new Otto:/)
      expect(new_otto.size).to eq(1)
      expect(new_otto.first).to include('[REDACTED] (1)')
      expect(lines.join("\n")).not_to include(mcp_token)
    end
  end

  # freeze_configuration! deep-freezes @option and the token list in it. MCP is
  # left disabled here so the freeze does not depend on the MCP middleware;
  # @option keeps the tokens either way.
  describe 'the frozen option Hash of an Otto instance' do
    let(:otto) do
      instance = Otto.new(nil, mcp_auth_tokens: [mcp_token])
      instance.freeze_configuration!
      instance
    end

    it 'keeps the tokens out of the FrozenError from a write to the Hash' do
      message = frozen_error_message { otto.option[:x] = 1 }

      expect(message).to start_with("can't modify frozen")
      expect(message).not_to include(mcp_token)
    end

    it 'keeps the tokens out of the FrozenError from a write to the token list' do
      message = frozen_error_message { otto.option[:mcp_auth_tokens] << 'y' }

      expect(message).to start_with("can't modify frozen")
      expect(message).not_to include(mcp_token)
    end

    it 'keeps the token out of the FrozenError from a write to one token' do
      message = frozen_error_message { otto.option[:mcp_auth_tokens].first << 'y' }

      expect(message).to start_with("can't modify frozen")
      expect(message).not_to include(mcp_token)
    end

    it 'keeps a single String token out of the FrozenError from a write to it' do
      single = Otto.new(nil, mcp_auth_tokens: mcp_token)
      single.freeze_configuration!
      message = frozen_error_message { single.option[:mcp_auth_tokens] << 'y' }

      expect(message).not_to include(mcp_token)
      expect(single.option[:mcp_auth_tokens]).to eq(mcp_token)
      expect(single.option[:mcp_auth_tokens]).to be_a(String)
    end

    it 'still reads like the Hash and Array it was' do
      tokens = otto.option[:mcp_auth_tokens]

      expect(otto.option).to be_a(Hash)
      expect(otto.option[:locale]).to eq('en')
      expect(tokens).to be_a(Array)
      expect(tokens).to eq([mcp_token])
      expect([mcp_token]).to eq(tokens)
      expect(tokens).to include(mcp_token)
      expect(tokens.to_a).to eq([mcp_token])
      expect(tokens.map(&:to_s)).to eq([mcp_token])
      expect("#{tokens.first}").to eq(mcp_token) # rubocop:disable Style/RedundantInterpolation
    end
  end

  describe Otto::Security::Authentication::Strategies::APIKeyStrategy do
    it 'keeps the configured keys out of #inspect (it stores digests in a closure)' do
      strategy = described_class.new(api_keys: ['api-key-value-0123456789'])

      expect(strategy.inspect).not_to include('api-key-value-0123456789')
    end
  end
end
