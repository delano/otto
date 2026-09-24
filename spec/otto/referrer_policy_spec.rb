# frozen_string_literal: true

require 'spec_helper'

# This is end-to-end coverage across routing, Rack::Files, and authentication;
# no single implementation class is the subject.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'configured Referrer-Policy responses' do
  let(:public_dir) { Dir.mktmpdir('otto_referrer_policy') }
  let(:routes_file) do
    create_test_routes_file('referrer_policy_routes.txt',
      [
        'GET /html ReferrerPolicySpecApp.html',
        'GET /override ReferrerPolicySpecApp.override',
        'GET /protected ReferrerPolicySpecApp.html auth=session',
      ])
  end
  let(:options) { {} }
  let(:app) do
    Otto.new(routes_file, { public: public_dir }.merge(options)).tap do |otto|
      otto.add_auth_strategy('session', Otto::Security::SessionStrategy.new)
    end
  end

  before do
    stub_const('ReferrerPolicySpecApp', Class.new do
      def self.html(_req, res)
        res['content-type'] = 'text/html'
        res.write('<h1>Referrer policy</h1>')
      end

      def self.override(_req, res)
        res['content-type'] = 'text/html'
        res['referrer-policy'] = 'same-origin'
        res.write('<h1>Explicit policy</h1>')
      end
    end)
    File.write(File.join(public_dir, 'app.css'), 'body { color: black; }')
  end

  after do
    FileUtils.rm_rf(public_dir)
  end

  def get(path)
    env = Rack::MockRequest.env_for(path)
    env['rack.session'] = {}
    status, headers, body = app.call(env)
    body_content = +''
    body.each { |chunk| body_content << chunk }
    body.close if body.respond_to?(:close)
    [status, headers, body_content]
  end

  shared_examples 'a consistent referrer policy' do
    it 'applies the policy to routed HTML responses' do
      status, headers, _body = get('/html')

      expect(status).to eq(200)
      expect(headers['referrer-policy']).to eq(expected_policy)
    end

    it 'applies the policy to actual Rack::Files responses' do
      status, headers, body = get('/app.css')

      expect(status).to eq(200)
      expect(body).to eq('body { color: black; }')
      expect(headers['referrer-policy']).to eq(expected_policy)
    end

    it 'applies the policy to RouteAuthWrapper-generated responses' do
      status, headers, _body = get('/protected')

      expect(status).to eq(302)
      expect(headers['referrer-policy']).to eq(expected_policy)
    end
  end

  context 'with the default configuration' do
    let(:expected_policy) { 'strict-origin-when-cross-origin' }

    it_behaves_like 'a consistent referrer policy'
  end

  context 'with a custom policy' do
    let(:options) { { referrer_policy: 'no-referrer' } }
    let(:expected_policy) { 'no-referrer' }

    it_behaves_like 'a consistent referrer policy'

    it 'preserves a policy set explicitly by the route handler' do
      _status, headers, _body = get('/override')

      expect(headers['referrer-policy']).to eq('same-origin')
    end
  end

  describe 'configuration validation' do
    it 'rejects an unknown policy through the dedicated option' do
      expect { Otto.new(nil, referrer_policy: 'send-everything') }
        .to raise_error(ArgumentError, /Invalid referrer_policy/)
    end

    it 'validates and canonicalizes the generic security_headers option' do
      configured = Otto.new(nil, security_headers: { 'Referrer-Policy' => 'origin' })

      expect(configured.security_config.referrer_policy).to eq('origin')
      expect(configured.security_config.security_headers).to include('referrer-policy' => 'origin')
      expect(configured.security_config.security_headers).not_to have_key('Referrer-Policy')
    end

    it 'gives the dedicated option precedence when both configuration APIs are present' do
      configured = Otto.new(nil,
        security_headers: { 'referrer-policy' => 'origin' },
        referrer_policy: 'no-referrer')

      expect(configured.security_config.referrer_policy).to eq('no-referrer')
    end

    it 'does not let direct generic-header mutation bypass validation' do
      config = Otto::Security::Config.new

      expect { config.security_headers['referrer-policy'] = 'send-everything' }
        .to raise_error(ArgumentError, /Invalid referrer_policy/)
    end

    it 'rejects an unknown policy through the generic security_headers option' do
      expect { Otto.new(nil, security_headers: { 'Referrer-Policy' => 'send-everything' }) }
        .to raise_error(ArgumentError, /Invalid referrer_policy/)
    end

    it 'accepts every W3C HTTP policy token' do
      config = Otto::Security::Config.new

      Otto::Security::Config::REFERRER_POLICIES.each do |policy|
        expect { config.referrer_policy = policy }.not_to raise_error
        expect(config.referrer_policy).to eq(policy)
      end
    end
  end
end
