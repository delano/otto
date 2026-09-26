# spec/otto/testing_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

# Otto::Testing is the test support implementing projects load with
# `require 'otto/testing'`. Nothing in it may depend on RSpec: the reset has
# to work from Tryouts and Minitest, and the env builder has to produce what
# IPPrivacyMiddleware would, so a harness never writes otto.client_ip alone.
RSpec.describe Otto::Testing do
  describe '.reset!' do
    it 'clears a committed family so a conflicting application can be built' do
      Otto.new(nil, trusted_proxy_depth: 1, trusted_proxy_header: 'Forwarded')
      expect { Otto.new(nil, trusted_proxy_depth: 1) }.to raise_error(ArgumentError, /already uses Forwarded/)

      described_class.reset!

      expect(Otto::Security::Config.rack_forwarding_family).to be_nil
      expect { Otto.new(nil, trusted_proxy_depth: 1) }.not_to raise_error
      expect(Rack::Request.forwarded_priority).to eq([:x_forwarded])
    end

    it "restores Rack's load-time forwarded_priority" do
      Rack::Request.forwarded_priority = [:forwarded]

      described_class.reset!

      expect(Rack::Request.forwarded_priority).to eq(Otto::Security::Config::DEFAULT_RACK_FORWARDED_PRIORITY)
    end

    it 'works in a process that never loaded RSpec' do
      # A subprocess is the only honest check: hiding the RSpec constant
      # in-process would still leave rspec's other state around.
      script = <<~RUBY
        abort 'RSpec is loaded in the subprocess' if defined?(RSpec)
        require 'otto/testing'
        Otto.logger.level = Logger::FATAL

        Otto.new(nil, trusted_proxy_depth: 1, trusted_proxy_header: 'Forwarded')
        begin
          Otto.new(nil, trusted_proxy_depth: 1)
          abort 'expected a forwarding family conflict'
        rescue ArgumentError => e
          abort "conflict message does not name the reset: \#{e.message}" unless e.message.include?('Otto::Testing.reset!')
        end

        begin
          Otto::Security::Config.reset_rack_forwarding_family_for_testing!
          abort 'the RSpec-only reset ran without RSpec'
        rescue RuntimeError => e
          abort "RSpec-only reset error does not name the replacement: \#{e.message}" unless e.message.include?('Otto::Testing.reset!')
        end

        Otto::Testing.reset!
        Otto.new(nil, trusted_proxy_depth: 1)
        print Rack::Request.forwarded_priority.inspect
      RUBY

      lib = File.expand_path('../../lib', __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', script)

      expect(status).to be_success, "subprocess failed: #{stderr}"
      expect(stdout).to end_with('[:x_forwarded]')
    end

    it 'leaves the RSpec-only reset working for existing callers' do
      Otto.new(nil, trusted_proxy_depth: 1, trusted_proxy_header: 'Forwarded')

      Otto::Security::Config.reset_rack_forwarding_family_for_testing!

      expect(Otto::Security::Config.rack_forwarding_family).to be_nil
    end
  end

  describe 'forwarding family conflict message' do
    it 'tells a test suite how to clear the family between tests' do
      Otto.new(nil, trusted_proxy_depth: 1, trusted_proxy_header: 'Forwarded')

      expect { Otto.new(nil, trusted_proxy_depth: 1) }
        .to raise_error(ArgumentError, %r{require 'otto/testing' and call Otto::Testing\.reset!})
    end
  end

  describe '.env_for' do
    let(:defaults) { Otto::Security::Config.new }

    it 'masks otto.client_ip while otto.ip_match sees the full address' do
      env = described_class.env_for('/', client_ip: '203.0.113.9', security_config: defaults)

      expect(env['otto.client_ip']).to eq('203.0.113.0')
      expect(env['REMOTE_ADDR']).to eq('203.0.113.0')
      expect(env['otto.ip_match'].call(['203.0.113.9/32'])).to be(true)
      expect(env['otto.ip_match'].call(['203.0.113.0/32'])).to be(false)
    end

    it 'leaves a private address unmasked, as the middleware does' do
      env = described_class.env_for('/', client_ip: '192.168.1.50', security_config: defaults)

      expect(env['otto.client_ip']).to eq('192.168.1.50')
      expect(env['otto.ip_match'].call(['192.168.1.50/32'])).to be(true)
    end

    it 'follows the privacy profile of the security config it is given' do
      defaults.ip_privacy_config.profile = :audit

      env = described_class.env_for('/', client_ip: '203.0.113.9', security_config: defaults)

      expect(env['otto.client_ip']).to eq('203.0.113.9')
      expect(env['otto.ip_match'].call(['203.0.113.9/32'])).to be(true)
    end

    it 'builds a request with no resolvable client IP from client_ip: nil' do
      env = described_class.env_for('/', client_ip: nil, security_config: defaults)

      expect(env['otto.client_ip']).to be_nil
      expect(env).not_to have_key('REMOTE_ADDR')
      expect(env['otto.ip_match'].call(['0.0.0.0/0', '::/0'])).to be(false)
    end

    it 'gives client_ip: nil a nil otto.client_ip under the audit profile too' do
      # The unmasked path writes the key with a nil value where the masking
      # path leaves it out; both read as nil.
      defaults.ip_privacy_config.profile = :audit

      env = described_class.env_for('/', client_ip: nil, security_config: defaults)

      expect(env['otto.client_ip']).to be_nil
      expect(env['otto.ip_match'].call(['0.0.0.0/0', '::/0'])).to be(false)
    end

    it 'refuses forwarded-for headers, which could resolve an address other than client_ip' do
      depth = Otto::Security::Config.new.tap { |c| c.trusted_proxy_depth = 1 }
      client_ips = [nil, '10.0.0.5']

      %w[HTTP_X_FORWARDED_FOR HTTP_X_REAL_IP HTTP_X_CLIENT_IP HTTP_FORWARDED].each do |header|
        client_ips.each do |client_ip|
          expect do
            described_class.env_for('/', client_ip: client_ip, security_config: depth, header => '203.0.113.9')
          end.to raise_error(ArgumentError, /#{header}.*resolve_client_ip!/)
        end
      end
    end

    it 'passes Rack::MockRequest options and env keys through' do
      env = described_class.env_for('/submit?x=1', client_ip: '203.0.113.9', security_config: defaults,
                                                   method: 'POST', 'HTTP_ACCEPT' => 'application/json')

      expect(env['REQUEST_METHOD']).to eq('POST')
      expect(env['PATH_INFO']).to eq('/submit')
      expect(env['QUERY_STRING']).to eq('x=1')
      expect(env['HTTP_ACCEPT']).to eq('application/json')
    end

    it 'records the proxy-trust verdict when the config configures trust' do
      defaults.add_trusted_proxy('10.0.0.0/8')

      env = described_class.env_for('/', client_ip: '203.0.113.9', security_config: defaults)

      expect(env['otto.via_trusted_proxy']).to be(false)
    end
  end

  describe '.resolve_client_ip!' do
    it 'resolves a proxied request in place' do
      security_config = Otto::Security::Config.new
      security_config.add_trusted_proxy('10.0.0.0/8')
      env = Rack::MockRequest.env_for('/', 'REMOTE_ADDR' => '10.0.0.5', 'HTTP_X_FORWARDED_FOR' => '203.0.113.9')

      result = described_class.resolve_client_ip!(env, security_config)

      expect(result).to equal(env)
      expect(env['otto.via_trusted_proxy']).to be(true)
      expect(env['otto.client_ip']).to eq('203.0.113.0')
      expect(env['otto.ip_match'].call(['203.0.113.9/32'])).to be(true)
      expect(env['otto.ip_match'].call(['10.0.0.5/32'])).to be(false)
    end

    it 'refuses an env that was already resolved' do
      env = described_class.env_for('/', client_ip: '203.0.113.9', security_config: Otto::Security::Config.new)

      expect { described_class.resolve_client_ip!(env, Otto::Security::Config.new) }
        .to raise_error(ArgumentError, /already carries otto\.client_ip or otto\.ip_match/)
    end

    it 'refuses an env whose no-IP resolution left only otto.ip_match' do
      env = described_class.env_for('/', client_ip: nil, security_config: Otto::Security::Config.new)
      expect(env).not_to have_key('otto.client_ip')

      expect { described_class.resolve_client_ip!(env, Otto::Security::Config.new) }
        .to raise_error(ArgumentError, /already carries/)
    end

    it 'raises when the middleware returns without installing otto.ip_match' do
      # The helper discards the middleware's response, so only the missing key
      # can reveal a path that answered before resolving. An env that drops
      # the write stands in for that path: the middleware class may already be
      # frozen when this runs, so it cannot be stubbed.
      drops_ip_match = Class.new(Hash) do
        def []=(key, value)
          super unless key == 'otto.ip_match'
        end
      end
      env = drops_ip_match.new.merge!(Rack::MockRequest.env_for('/', 'REMOTE_ADDR' => '203.0.113.9'))

      expect { described_class.resolve_client_ip!(env, Otto::Security::Config.new) }
        .to raise_error(RuntimeError, /without installing otto\.ip_match/)
    end
  end

  # The regression the builder exists for: a harness env handed to a real
  # Otto application, whose own IPPrivacyMiddleware treats otto.client_ip as
  # a prior pass.
  describe 'an env built by .env_for, sent through an Otto application' do
    let(:captured) { {} }
    let(:otto) do
      sink = captured
      routes_file = create_test_routes_file('testing_env_for.txt', ['GET /probe &probe'])
      Otto.new(routes_file, trusted_proxies: ['10.0.0.0/8'], lambda_handlers: {
                 'probe' => ->(req, _res, _extra) { sink[:env] = req.env },
               })
    end

    it 'keeps the precise ip_match and the trust verdict, without the fail-closed warning' do
      env = described_class.env_for('/probe', client_ip: '203.0.113.9', security_config: otto.security_config)
      allow(Otto.logger).to receive(:warn)

      otto.call(env)

      expect(Otto.logger).not_to have_received(:warn)
      expect(captured[:env]['otto.client_ip']).to eq('203.0.113.0')
      expect(captured[:env]['otto.ip_match'].call(['203.0.113.9/32'])).to be(true)
      expect(captured[:env]['otto.via_trusted_proxy']).to be(false)
    end

    it 'matches the forwarded client when a relayed env is resolved under the app config' do
      sink = captured
      routes_file = create_test_routes_file('testing_depth.txt', ['GET /probe &probe'])
      depth_app = Otto.new(routes_file, trusted_proxy_depth: 1, lambda_handlers: {
                             'probe' => ->(req, _res, _extra) { sink[:env] = req.env },
                           })
      env = Rack::MockRequest.env_for('/probe', 'REMOTE_ADDR' => '10.0.0.5', 'HTTP_X_FORWARDED_FOR' => '203.0.113.9')

      described_class.resolve_client_ip!(env, depth_app.security_config)
      depth_app.call(env)

      expect(captured[:env]['otto.via_trusted_proxy']).to be(true)
      expect(captured[:env]['otto.ip_match'].call(['203.0.113.9/32'])).to be(true)
      expect(captured[:env]['otto.ip_match'].call(['10.0.0.5/32'])).to be(false)
    end

    it 'denies every range when the harness writes otto.client_ip by hand' do
      env = Rack::MockRequest.env_for('/probe', 'REMOTE_ADDR' => '203.0.113.9')
      env['otto.client_ip'] = '203.0.113.9'
      allow(Otto.logger).to receive(:warn)

      otto.call(env)

      expect(Otto.logger).to have_received(:warn).with(/Otto::Testing\.env_for/)
      expect(captured[:env]['otto.ip_match'].call(['203.0.113.9/32'])).to be(false)
    end
  end
end
