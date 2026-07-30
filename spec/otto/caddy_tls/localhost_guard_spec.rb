# spec/otto/caddy_tls/localhost_guard_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::CaddyTLS::LocalhostGuard do
  let(:endpoint) { '/_caddy/tls-permission' }

  # A downstream app that records whether it was reached and with which env.
  let(:downstream) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def call(env)
        @calls << env
        [200, { 'content-type' => 'text/plain' }, ['passed-through']]
      end
    end.new
  end

  subject(:guard) { described_class.new(downstream, endpoint) }

  def env_for(path: '/_caddy/tls-permission', remote_addr: '127.0.0.1', headers: {})
    {
      'REQUEST_METHOD' => 'GET',
      'PATH_INFO' => path,
      'REMOTE_ADDR' => remote_addr,
    }.merge(headers)
  end

  def call(**opts)
    guard.call(env_for(**opts))
  end

  describe 'requests to the protected endpoint' do
    context 'from a loopback peer' do
      %w[127.0.0.1 ::1 ::ffff:127.0.0.1 127.5.5.5].each do |addr|
        it "allows #{addr} (passes through to the app)" do
          response = call(remote_addr: addr)
          expect(response[2]).to eq(['passed-through'])
          expect(downstream.calls.size).to eq(1)
        end
      end
    end

    context 'from a non-loopback peer' do
      %w[10.0.0.1 8.8.8.8 192.168.1.1 2001:db8::1 ::ffff:8.8.8.8].each do |addr|
        it "denies #{addr} with 401 (app never reached)" do
          status, headers, body = call(remote_addr: addr)
          expect(status).to eq(401)
          expect(headers['content-type']).to eq('text/plain')
          expect(body).to eq(['Unauthorized'])
          expect(downstream.calls).to be_empty
        end
      end
    end

    context 'with a malformed or missing peer address' do
      ['', '   ', 'garbage', 'not-an-ip', '127.0.0.1:53422', nil].each do |addr|
        it "denies #{addr.inspect} with 401 (fail-closed)" do
          expect(call(remote_addr: addr)[0]).to eq(401)
          expect(downstream.calls).to be_empty
        end
      end
    end
  end

  describe 'raw-peer authentication (spoofing resistance)' do
    it 'denies a non-loopback peer even when X-Forwarded-For claims loopback' do
      # The guard reads the raw socket peer, never a forwarded header, so a
      # spoofed XFF cannot promote a remote client to "localhost".
      status, = call(remote_addr: '8.8.8.8', headers: { 'HTTP_X_FORWARDED_FOR' => '127.0.0.1' })
      expect(status).to eq(401)
      expect(downstream.calls).to be_empty
    end

    it 'denies when X-Forwarded-For chains multiple loopback claims' do
      status, = call(remote_addr: '203.0.113.7',
                     headers: { 'HTTP_X_FORWARDED_FOR' => '127.0.0.1, ::1' })
      expect(status).to eq(401)
    end
  end

  # IPPrivacyMiddleware is pinned outermost (issue #219), so it runs AHEAD of
  # this guard and may have rewritten REMOTE_ADDR by the time the guard sees the
  # env. It records its verdict on the untouched peer in env['otto.peer_loopback'],
  # which the guard prefers over the (possibly rewritten) address.
  describe "env['otto.peer_loopback'] (pre-masking peer record)" do
    it 'allows when the record says loopback but REMOTE_ADDR was since rewritten' do
      # What a masked private-IP deployment looks like: peer was ::1, privacy
      # masked it to an address that no longer reads as loopback.
      response = call(remote_addr: '::', headers: { 'otto.peer_loopback' => true })
      expect(response[2]).to eq(['passed-through'])
    end

    it 'denies when the record says non-loopback even if REMOTE_ADDR now reads as loopback' do
      # The exploit the raw-peer rule exists to stop: a trusted loopback proxy
      # resolving a spoofed `X-Forwarded-For: 127.0.0.1` into REMOTE_ADDR.
      status, = call(remote_addr: '127.0.0.1', headers: { 'otto.peer_loopback' => false })
      expect(status).to eq(401)
      expect(downstream.calls).to be_empty
    end

    it 'falls back to REMOTE_ADDR when the record is absent or not a Boolean' do
      expect(call(remote_addr: '127.0.0.1')[0]).to eq(200)
      expect(call(remote_addr: '8.8.8.8')[0]).to eq(401)
      # A non-Boolean is not a verdict — evaluate the address instead.
      expect(call(remote_addr: '8.8.8.8', headers: { 'otto.peer_loopback' => 'true' })[0]).to eq(401)
      expect(call(remote_addr: '127.0.0.1', headers: { 'otto.peer_loopback' => nil })[0]).to eq(200)
    end

    it 'still requires the absence of forwarding headers' do
      status, = call(remote_addr: '127.0.0.1',
                     headers: { 'otto.peer_loopback' => true, 'HTTP_X_FORWARDED_FOR' => '203.0.113.9' })
      expect(status).to eq(401)
    end
  end

  describe 'behind IPPrivacyMiddleware (the real Otto stack order)' do
    let(:security_config) { Otto::Security::Config.new }

    # IPPrivacy outermost -> guard -> downstream, exactly as Otto builds it.
    def stack_call(env)
      Otto::Security::Middleware::IPPrivacyMiddleware.new(guard, security_config).call(env)
    end

    it 'allows a direct loopback call' do
      status, = stack_call(env_for(remote_addr: '127.0.0.1'))
      expect(status).to eq(200)
    end

    it 'denies a remote peer whose spoofed XFF resolves to loopback through a trusted proxy' do
      security_config.add_trusted_proxy('203.0.113.7')

      env = env_for(remote_addr: '203.0.113.7', headers: { 'HTTP_X_FORWARDED_FOR' => '127.0.0.1' })
      status, = stack_call(env)

      # Resolution promoted REMOTE_ADDR to loopback...
      expect(env['REMOTE_ADDR']).to eq('127.0.0.1')
      # ...but the guard authenticates the recorded raw peer, so: denied.
      expect(env['otto.peer_loopback']).to be false
      expect(status).to eq(401)
      expect(downstream.calls).to be_empty
    end

    it 'denies a remote peer when masking is on for private IPs too' do
      # mask_private_ips rewrites even loopback, so REMOTE_ADDR alone would be
      # an unreliable basis for the decision in both directions.
      security_config.ip_privacy_config.mask_private_ips = true

      env = env_for(remote_addr: '8.8.8.8')
      expect(stack_call(env)[0]).to eq(401)
    end

    it 'allows a direct IPv6 loopback call even when masking rewrites ::1' do
      security_config.ip_privacy_config.mask_private_ips = true

      env = env_for(remote_addr: '::1')
      status, = stack_call(env)

      expect(env['REMOTE_ADDR']).not_to eq('::1') # masked out of loopback range
      expect(status).to eq(200)
    end
  end

  describe 'relayed requests (proxy forwarding headers)' do
    # A direct control-plane call from a co-located proxy carries no forwarding
    # headers. A request that was *relayed through* a proxy (even one connecting
    # over loopback) carries one — so it is denied despite the loopback peer.
    # This is what keeps the endpoint safe when mounted inside a proxied app.
    {
      'HTTP_X_FORWARDED_FOR' => '203.0.113.9',
      'HTTP_X_REAL_IP' => '203.0.113.9',
      'HTTP_X_CLIENT_IP' => '203.0.113.9',
      'HTTP_FORWARDED' => 'for=203.0.113.9',
    }.each do |header, value|
      it "denies a loopback peer carrying #{header} with 401" do
        status, = call(remote_addr: '127.0.0.1', headers: { header => value })
        expect(status).to eq(401)
        expect(downstream.calls).to be_empty
      end
    end

    it 'denies even when the forwarding header itself claims loopback' do
      status, = call(remote_addr: '127.0.0.1', headers: { 'HTTP_X_FORWARDED_FOR' => '127.0.0.1' })
      expect(status).to eq(401)
    end

    it 'ignores a blank forwarding header (still a direct call)' do
      response = call(remote_addr: '127.0.0.1', headers: { 'HTTP_X_FORWARDED_FOR' => '   ' })
      expect(response[2]).to eq(['passed-through'])
    end

    it 'does not apply the forwarding check to unrelated paths' do
      response = guard.call(
        env_for(path: '/health', remote_addr: '10.0.0.1', headers: { 'HTTP_X_FORWARDED_FOR' => '1.2.3.4' })
      )
      expect(response[2]).to eq(['passed-through'])
    end
  end

  describe 'path normalization matches the router' do
    # The router unescapes, drops invalid UTF-8 bytes, and strips a trailing
    # slash before matching. If the guard normalized differently, a crafted
    # invalid byte could make the router route a path the guard let through.
    it 'still guards an endpoint path with a trailing invalid byte (non-loopback)' do
      status, = guard.call(env_for(path: "/_caddy/tls-permission\xFF", remote_addr: '8.8.8.8'))
      expect(status).to eq(401)
    end

    it 'still guards a percent-encoded invalid byte on the endpoint (non-loopback)' do
      status, = guard.call(env_for(path: '/_caddy/tls-permission%FF', remote_addr: '8.8.8.8'))
      expect(status).to eq(401)
    end
  end

  describe 'path scoping' do
    it 'passes non-endpoint paths straight through regardless of peer' do
      response = guard.call(env_for(path: '/anything-else', remote_addr: '8.8.8.8'))
      expect(response[2]).to eq(['passed-through'])
      expect(downstream.calls.size).to eq(1)
    end

    it 'still guards a trailing-slash variant of the endpoint' do
      status, = guard.call(env_for(path: '/_caddy/tls-permission/', remote_addr: '8.8.8.8'))
      expect(status).to eq(401)
    end

    it 'still guards a percent-encoded variant of the endpoint' do
      # '%6e' decodes to 'n' — the router would still route this, so the guard
      # must normalize identically or it could be bypassed.
      status, = guard.call(env_for(path: '/_caddy/tls-permissio%6e', remote_addr: '8.8.8.8'))
      expect(status).to eq(401)
    end

    it 'allows a loopback peer on the trailing-slash variant' do
      response = guard.call(env_for(path: '/_caddy/tls-permission/', remote_addr: '127.0.0.1'))
      expect(response[2]).to eq(['passed-through'])
    end
  end

  describe 'endpoint normalization at construction' do
    it 'treats a configured endpoint with a trailing slash the same as without' do
      g = described_class.new(downstream, '/_caddy/tls-permission/')
      status, = g.call(env_for(path: '/_caddy/tls-permission', remote_addr: '8.8.8.8'))
      expect(status).to eq(401)
    end
  end
end
