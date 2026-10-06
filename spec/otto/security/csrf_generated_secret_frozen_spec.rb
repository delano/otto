# spec/otto/security/csrf_generated_secret_frozen_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

# Without OTTO_CSRF_SECRET or csrf_secret=, Security::Config signs CSRF tokens
# with a generated secret and logs a warning about it once per config. Otto
# skips its lazy configuration freeze under RSpec (see Otto#call), so the
# normal request path never generates a token through a genuinely frozen
# config. These specs freeze explicitly: generating a token after the
# freeze must not raise, and the warning must still be logged exactly once.
# The examples without a freeze cover an unfrozen config, and both production
# examples check that the raise comes before the warning.
# Integration spec over a behaviour, not a class; same shape as
# csp_extras_frozen_spec.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'CSRF generated-secret warning against a frozen configuration' do
  include Rack::Test::Methods

  # Routes-file controllers must be resolvable by name, hence a real constant
  # (the same pattern as FrozenCspExtrasApp in csp_extras_frozen_spec).
  # rubocop:disable-next Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
  class FrozenCsrfGeneratedSecretApp
    # Controller ivars, not spec state.
    # rubocop:disable RSpec/InstanceVariable
    def initialize(_req, res)
      @res = res
    end

    def index
      @res['content-type'] = 'text/html; charset=utf-8'
      @res.write('<html><head><title>t</title></head><body>ok</body></html>')
    end
    # rubocop:enable RSpec/InstanceVariable
  end

  let(:warning) { /CSRF tokens are signed with a randomly generated secret/ }

  let(:config) do
    cfg = Otto::Security::Config.new
    cfg.enable_csrf_protection!
    cfg
  end

  around do |example|
    original_secret = ENV.fetch('OTTO_CSRF_SECRET', nil)
    original_env    = ENV.fetch('RACK_ENV', nil)
    ENV.delete('OTTO_CSRF_SECRET')
    example.run
  ensure
    ENV['OTTO_CSRF_SECRET'] = original_secret
    ENV['RACK_ENV']         = original_env
  end

  before do
    # A non-production environment, where the generated secret is allowed and
    # only warned about (production raises instead).
    ENV['RACK_ENV'] = 'development'
    allow(Otto.logger).to receive(:warn)
  end

  describe 'Otto::Security::Config#generate_csrf_token without a freeze' do
    it 'logs the warning once across repeated generation' do
      3.times { |i| config.generate_csrf_token("session_#{i}") }

      expect(config.frozen?).to be false
      expect(Otto.logger).to have_received(:warn).with(warning).once
    end

    it 'in production, raises before logging the warning' do
      ENV['RACK_ENV'] = 'production'

      expect { config.generate_csrf_token('session_a') }
        .to raise_error(ArgumentError, Otto::Security::Config::CSRF_SECRET_REQUIRED_MESSAGE)
      expect(Otto.logger).not_to have_received(:warn).with(warning)
    end
  end

  describe 'Otto::Security::Config#generate_csrf_token after deep_freeze!' do
    it 'generates a verifiable token without raising' do
      config.deep_freeze!

      token = nil
      expect { token = config.generate_csrf_token('session_a') }.not_to raise_error
      expect(config.verify_csrf_token(token, 'session_a')).to be true
    end

    it 'logs the generated-secret warning exactly once across freeze and repeated generation' do
      config.deep_freeze!
      3.times { |i| config.generate_csrf_token("session_#{i}") }

      expect(Otto.logger).to have_received(:warn).with(warning).once
    end

    it 'logs the warning once when a token was generated before the freeze' do
      config.generate_csrf_token('session_before')
      config.deep_freeze!
      config.generate_csrf_token('session_after')

      expect(Otto.logger).to have_received(:warn).with(warning).once
    end

    it 'does not log the warning when a secret is configured' do
      config.csrf_secret = SecureRandom.hex(32)
      config.deep_freeze!
      config.generate_csrf_token('session_a')

      expect(Otto.logger).not_to have_received(:warn).with(warning)
    end

    # validate_csrf_secret_config! raises before it calls the warning.
    it 'in production, raises at freeze time before logging the warning' do
      ENV['RACK_ENV'] = 'production'

      expect { config.deep_freeze! }
        .to raise_error(ArgumentError, Otto::Security::Config::CSRF_SECRET_REQUIRED_MESSAGE)
      expect(Otto.logger).not_to have_received(:warn).with(warning)
    end

    it 'with CSRF protection disabled, does not warn at freeze time' do
      Otto::Security::Config.new.deep_freeze!

      expect(Otto.logger).not_to have_received(:warn).with(warning)
    end

    # CSRFHelpers#csrf_token can still mint tokens with CSRF disabled, and
    # those tokens are signed with the generated secret too.
    it 'with CSRF protection disabled, warns once when tokens are generated after the freeze' do
      disabled = Otto::Security::Config.new.deep_freeze!

      expect { 3.times { |i| disabled.generate_csrf_token("session_#{i}") } }.not_to raise_error
      expect(Otto.logger).to have_received(:warn).with(warning).once
    end

    it 'logs the warning once when threads generate the first tokens concurrently' do
      disabled = Otto::Security::Config.new.deep_freeze!
      start    = Queue.new

      # rubocop:disable-next ThreadSafety/NewThread
      threads = Array.new(16) do |i|
        Thread.new do
          start.pop
          disabled.generate_csrf_token("session_#{i}")
        end
      end
      16.times { start << true }
      threads.each(&:join)

      expect(Otto.logger).to have_received(:warn).with(warning).once
    end

    it 'says which processes share a generated secret, without logging the secret' do
      messages = []
      allow(Otto.logger).to receive(:warn) { |message| messages << message }
      config.deep_freeze!

      expect(messages.size).to eq(1)
      message = messages.first
      expect(message).to include('Workers forked after the secret was generated (a preloaded app) share it')
      expect(message).to include('workers that load the app themselves (cluster mode without preload)')
      expect(message).to include('processes started separately, other hosts and restarts')
      expect(message).not_to include(config.instance_variable_get(:@csrf_secret))
    end

    it 'names the same cases in the production error' do
      message = Otto::Security::Config::CSRF_SECRET_REQUIRED_MESSAGE

      expect(message).to include('workers that load the app themselves (cluster mode without preload)')
      expect(message).to include('processes started separately, other hosts or a restart')
    end
  end

  describe 'an Otto app with CSRF enabled and a generated secret' do
    let(:routes_file) do
      file = Tempfile.new(['frozen_csrf_generated_secret_routes', '.txt'])
      file.write("GET / FrozenCsrfGeneratedSecretApp#index\n")
      file.flush
      file
    end

    let(:otto) do
      instance = Otto.new(routes_file.path)
      instance.enable_csrf_protection!
      # Freeze the whole instance the way the first real request would outside
      # the test suite (RSpec skips this). freeze_configuration! is private.
      instance.send(:freeze_configuration!)
      instance
    end

    def app
      otto
    end

    after { routes_file.close! }

    it 'freezes the security config (the precondition this spec exists for)' do
      expect(otto.security_config.frozen?).to be true
    end

    it 'serves HTML pages with an injected CSRF token' do
      2.times do
        get '/'

        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<meta name="csrf-token" content="')
      end
      expect(Otto.logger).to have_received(:warn).with(warning).once
    end
  end
end
