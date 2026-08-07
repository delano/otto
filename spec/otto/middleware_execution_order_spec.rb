# spec/otto/middleware_execution_order_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Regression coverage for issue #219.
#
# IPPrivacyMiddleware was registered `position: :first`, which is first-in-ARRAY
# and therefore INNERMOST once MiddlewareStack#wrap folds the stack with reduce.
# The result inverted the documented contract: only the wrapped application saw
# masked IPs, while every other middleware Otto mounts saw the raw REMOTE_ADDR
# and a nil otto.client_ip.
#
# These specs pin what OTHER MIDDLEWARE observes, not just what the app observes
# — the distinction the previous coverage missed entirely.
RSpec.describe 'Middleware execution order' do
  # A pass-through that records the env exactly as it was handed to it.
  def probe_class
    Class.new do
      class << self
        attr_accessor :seen
      end

      def initialize(app, *_args, **_opts) = (@app = app)

      def call(env)
        self.class.seen = {
          remote_addr: env['REMOTE_ADDR'],
             user_agent: env['HTTP_USER_AGENT'],
              client_ip: env['otto.client_ip'],
                    xff: env['HTTP_X_FORWARDED_FOR'],
        }
        @app.call(env)
      end
    end
  end

  let(:probe) { probe_class }

  let(:otto) do
    instance = Otto.new
    Otto.unfreeze_for_testing(instance)
    instance
  end

  def request_env(remote_addr: '203.0.113.7', headers: {})
    {
      'REQUEST_METHOD' => 'GET',
             'PATH_INFO' => '/',
         'QUERY_STRING' => '',
          'REMOTE_ADDR' => remote_addr,
      'HTTP_USER_AGENT' => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/120.0.6099.109',
           'rack.input' => StringIO.new(''),
    }.merge(headers)
  end

  describe 'IP privacy is the entry point of the stack' do
    it 'runs first, before any middleware the app adds' do
      otto.use(probe)

      expect(otto.middleware.execution_order.first)
        .to eq(Otto::Security::Middleware::IPPrivacyMiddleware)
      expect(otto.middleware.execution_order.last).to eq(probe)
    end

    it 'hands other middleware a masked REMOTE_ADDR and the canonical client IP' do
      otto.use(probe)

      otto.call(request_env)

      expect(probe.seen[:remote_addr]).to eq('203.0.113.0')
      expect(probe.seen[:client_ip]).to eq('203.0.113.0')
    end

    it 'hands other middleware an anonymized User-Agent' do
      otto.use(probe)

      otto.call(request_env)

      expect(probe.seen[:user_agent]).not_to include('10_15_7')
    end

    it 'masks forwarded headers before other middleware reads them' do
      otto.use(probe)

      otto.call(request_env(headers: { 'HTTP_X_FORWARDED_FOR' => '203.0.113.7' }))

      expect(probe.seen[:xff]).to eq('203.0.113.0')
    end

    it 'stays first when rate limiting is enabled (the reported reproduction)' do
      otto.enable_rate_limiting!
      otto.use(probe)

      expect(otto.middleware.execution_order.first)
        .to eq(Otto::Security::Middleware::IPPrivacyMiddleware)

      otto.call(request_env)
      expect(probe.seen[:remote_addr]).to eq('203.0.113.0')
      expect(probe.seen[:client_ip]).to eq('203.0.113.0')
    end

    it 'stays first when a middleware is pinned :outermost' do
      otto.enable_csp_reporting!('/_/csp-report') { |_report| nil }
      otto.use(probe)

      expect(otto.middleware.execution_order.first)
        .to eq(Otto::Security::Middleware::IPPrivacyMiddleware)
      expect(otto.middleware.execution_order[1])
        .to eq(Otto::Security::CSP::ReportMiddleware)
    end

    it 'stays first regardless of how many middleware are added after it' do
      # probe_class mints a fresh anonymous class per call, so these are five
      # distinct entries — not one entry deduplicated by #add's identical-config
      # check. Asserted, because the pin is only interesting if they all landed.
      5.times { otto.use(probe_class) }
      expect(otto.middleware.size).to eq(6) # 5 probes + the IP-privacy pin

      expect(otto.middleware.execution_order.first)
        .to eq(Otto::Security::Middleware::IPPrivacyMiddleware)
    end
  end

  describe 'exemptions still apply to other middleware' do
    it 'leaves private/localhost addresses unmasked' do
      otto.use(probe)

      otto.call(request_env(remote_addr: '127.0.0.1'))

      expect(probe.seen[:remote_addr]).to eq('127.0.0.1')
      expect(probe.seen[:client_ip]).to eq('127.0.0.1')
    end

    it 'gives other middleware the real IP when privacy is disabled' do
      otto.security_config.ip_privacy_config.disable!
      otto.use(probe)

      otto.call(request_env)

      expect(probe.seen[:remote_addr]).to eq('203.0.113.7')
      expect(probe.seen[:client_ip]).to eq('203.0.113.7')
    end
  end

  describe 'pre-masking peer records' do
    it 'records the raw-peer facts before any other middleware runs' do
      seen = nil
      recorder = Class.new do
        define_method(:initialize) { |app, *_a, **_o| @app = app }
        define_method(:call) do |env|
          seen = env.slice('otto.via_trusted_proxy', 'otto.peer_loopback')
          @app.call(env)
        end
      end
      otto.use(recorder)

      otto.call(request_env(remote_addr: '127.0.0.1'))

      # No proxy trust is configured on this Otto instance, so the tri-state
      # otto.via_trusted_proxy key is deliberately ABSENT (not false): absence
      # is the signal that lets downstream consumers fall back to their own
      # heuristics without a spurious false vetoing them.
      expect(seen).to eq('otto.peer_loopback' => true)
    end
  end
end
