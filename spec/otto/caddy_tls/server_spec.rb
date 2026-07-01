# spec/otto/caddy_tls/server_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::CaddyTLS do
  # An empty-ish routes file; the permission route is registered programmatically.
  let(:otto) { create_minimal_otto(['GET /health HealthProbe.ok']) }
  let(:endpoint) { '/_caddy/tls-permission' }

  # Referenced by the routes file above so loading succeeds.
  class HealthProbe
    def self.ok(_req, res)
      res.body = ['ok']
    end
  end

  def request(path: '/_caddy/tls-permission', query: {}, remote_addr: '127.0.0.1')
    env = mock_rack_env(method: 'GET', path: path, params: query)
    env['REMOTE_ADDR'] = remote_addr
    otto.call(env)
  end

  def body_of(response)
    parts = []
    response[2].each { |chunk| parts << chunk }
    parts.join
  end

  describe '#enable_caddy_tls!' do
    it 'reports enabled once configured' do
      expect(otto.caddy_tls_enabled?).to be(false)
      otto.enable_caddy_tls! { |_domain| true }
      expect(otto.caddy_tls_enabled?).to be(true)
    end

    it 'requires a permission block (no allow-all default)' do
      expect { otto.enable_caddy_tls! }
        .to raise_error(ArgumentError, /requires a permission block/)
      expect(otto.caddy_tls_enabled?).to be(false)
    end

    it 'cannot be enabled after configuration is frozen' do
      otto.freeze_configuration!
      expect { otto.enable_caddy_tls! { |_d| true } }
        .to raise_error(FrozenError, /Cannot modify frozen configuration/)
    end

    it 'is idempotent: a second enable does not duplicate the route' do
      otto.enable_caddy_tls! { |_d| true }
      otto.enable_caddy_tls! { |_d| false } # ignored
      get_routes = otto.routes[:GET].select { |r| r.path == endpoint }
      expect(get_routes.size).to eq(1)
    end

    it 'keeps the original block on a repeated enable (idempotent)' do
      otto.enable_caddy_tls! { |_d| true } # allows everything
      otto.enable_caddy_tls! { |_d| false } # would deny — must be ignored
      expect(request(query: { domain: 'x.example.com' })[0]).to eq(200)
    end
  end

  describe 'permission decision' do
    before do
      allowlist = %w[verified.example.com]
      otto.enable_caddy_tls! { |domain| allowlist.include?(domain) }
    end

    it 'returns 200 OK for an allowed domain' do
      response = request(query: { domain: 'verified.example.com' })
      expect(response[0]).to eq(200)
      expect(body_of(response)).to eq('OK')
      expect(response[1]['content-type']).to eq('text/plain')
    end

    it 'returns 403 Forbidden for a denied domain' do
      response = request(query: { domain: 'unknown.example.com' })
      expect(response[0]).to eq(403)
      expect(body_of(response)).to eq('Forbidden')
    end

    it 'returns 400 when the domain parameter is missing' do
      response = request(query: {})
      expect(response[0]).to eq(400)
      expect(body_of(response)).to include('domain parameter required')
    end

    it 'returns 400 when the domain parameter is blank' do
      expect(request(query: { domain: '' })[0]).to eq(400)
    end

    it 'returns 400 for an array-valued domain param (never coerced to a string)' do
      # ?domain[]=a&domain[]=b parses to an Array; it must not reach the block
      # as a garbage string like '["a", "b"]'.
      env = mock_rack_env(method: 'GET', path: endpoint, params: { 'domain' => %w[a.com b.com] })
      env['REMOTE_ADDR'] = '127.0.0.1'
      expect(otto.call(env)[0]).to eq(400)
    end

    it 'consults only ?domain= (ignores other query params)' do
      # The removed check_verification bypass must stay removed: extra params
      # never reach the decision.
      response = request(query: { domain: 'unknown.example.com', check_verification: 'false' })
      expect(response[0]).to eq(403)
    end

    it 'returns an empty body for a HEAD request (Rack HEAD contract)' do
      env = mock_rack_env(method: 'HEAD', path: endpoint, params: { domain: 'verified.example.com' })
      env['REMOTE_ADDR'] = '127.0.0.1'
      status, _headers, body = otto.call(env)
      expect(status).to eq(200)
      expect(body_of([status, _headers, body])).to eq('')
    end
  end

  describe 'multi-instance isolation' do
    it 'evaluates each instance endpoint against its own permission block' do
      a = create_minimal_otto(['GET /a AProbe.ok'])
      b = create_minimal_otto(['GET /b BProbe.ok'])
      stub_const('AProbe', Class.new { def self.ok(_r, res); res.body = ['a']; end })
      stub_const('BProbe', Class.new { def self.ok(_r, res); res.body = ['b']; end })
      a.enable_caddy_tls! { |domain| domain == 'a.example.com' }
      b.enable_caddy_tls! { |domain| domain == 'b.example.com' } # enabled second

      call_ep = lambda do |otto, domain|
        env = mock_rack_env(method: 'GET', path: '/_caddy/tls-permission', params: { domain: domain })
        env['REMOTE_ADDR'] = '127.0.0.1'
        otto.call(env)[0]
      end

      # Each endpoint must consult ITS OWN block, not the last-enabled one.
      expect(call_ep.call(a, 'a.example.com')).to eq(200)
      expect(call_ep.call(a, 'b.example.com')).to eq(403)
      expect(call_ep.call(b, 'b.example.com')).to eq(200)
      expect(call_ep.call(b, 'a.example.com')).to eq(403)
    end
  end

  describe 'fail-closed decision' do
    it 'denies (403) when the permission block raises' do
      otto.enable_caddy_tls! { |_domain| raise 'boom' }
      expect(request(query: { domain: 'x.example.com' })[0]).to eq(403)
    end

    it 'denies (403) when the permission block returns nil' do
      otto.enable_caddy_tls! { |_domain| nil }
      expect(request(query: { domain: 'x.example.com' })[0]).to eq(403)
    end

    it 'logs the raised error while denying' do
      otto.enable_caddy_tls! { |_domain| raise 'kaboom' }
      allow(Otto).to receive(:structured_log) # catch-all for the :info decision + debug logs
      expect(Otto).to receive(:structured_log)
        .with(:error, a_string_matching(/permission callback raised/), hash_including(:error))
      request(query: { domain: 'x.example.com' })
    end
  end

  describe 'localhost guard' do
    it 'is installed by default and denies a non-loopback caller (401)' do
      otto.enable_caddy_tls! { |_domain| true }
      response = request(query: { domain: 'verified.example.com' }, remote_addr: '8.8.8.8')
      expect(response[0]).to eq(401)
    end

    it 'allows a loopback caller through to the decision' do
      otto.enable_caddy_tls! { |_domain| true }
      expect(request(query: { domain: 'x.example.com' }, remote_addr: '127.0.0.1')[0]).to eq(200)
    end

    it 'can be disabled with localhost_only: false' do
      otto.enable_caddy_tls!(localhost_only: false) { |_domain| true }
      response = request(query: { domain: 'x.example.com' }, remote_addr: '8.8.8.8')
      # Reaches the decision (no 401 guard); allowed => 200.
      expect(response[0]).to eq(200)
    end

    it 'does not install the guard middleware when localhost_only: false' do
      otto.enable_caddy_tls!(localhost_only: false) { |_domain| true }
      expect(otto.middleware_enabled?(Otto::CaddyTLS::LocalhostGuard)).to be(false)
    end
  end

  describe 'custom endpoint' do
    it 'serves at a configured endpoint path' do
      otto.enable_caddy_tls!(endpoint: '/internal/acme/ask') { |_domain| true }
      response = request(path: '/internal/acme/ask', query: { domain: 'x.example.com' })
      expect(response[0]).to eq(200)
    end
  end
end
