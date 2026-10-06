# spec/otto/utils_resolve_client_ip_rightmost_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# CIDR filter mode reads X-Forwarded-For from the right. A proxy that appends
# writes the address it received the request from after whatever the client
# sent, so every entry left of the one the outermost trusted proxy wrote is
# client supplied. These mirror the depth-mode forged-leftmost test in
# utils_spec.rb for filter mode.
RSpec.describe Otto::Utils, '.resolve_client_ip' do
  context 'with trusted_proxies (CIDR filter mode)' do
    let(:config) do
      Otto::Security::Config.new.tap { |cfg| cfg.add_trusted_proxy('10.0.0.0/8') }
    end

    def resolve(headers)
      described_class.resolve_client_ip({ 'REMOTE_ADDR' => '10.0.0.1' }.merge(headers), config)
    end

    it 'ignores a forged leftmost X-Forwarded-For entry' do
      # 9.9.9.9 is client supplied; the trusted proxy appended 203.0.113.50.
      expect(resolve('HTTP_X_FORWARDED_FOR' => '9.9.9.9, 203.0.113.50')).to eq('203.0.113.50')
    end

    it 'skips trusted hops on the right and stops at the first untrusted entry' do
      expect(resolve('HTTP_X_FORWARDED_FOR' => '9.9.9.9, 203.0.113.50, 10.0.0.9')).to eq('203.0.113.50')
    end

    it 'skips a trusted hop written in IPv4-mapped IPv6 form' do
      # trusted_proxy? folds ::ffff:10.0.0.9 to 10.0.0.9 before matching.
      expect(resolve('HTTP_X_FORWARDED_FOR' => '9.9.9.9, 203.0.113.50, ::ffff:10.0.0.9')).to eq('203.0.113.50')
    end

    it 'strips ports from entries in a multi-entry chain' do
      expect(resolve('HTTP_X_FORWARDED_FOR' => '9.9.9.9:1, 203.0.113.50:4711, 10.0.0.9:443')).to eq('203.0.113.50')
      expect(resolve('HTTP_X_FORWARDED_FOR' => '[2001:db8::bad]:1, [2001:db8::7]:443, 10.0.0.9')).to eq('2001:db8::7')
    end

    it 'walks a multi-hop IPv6 chain behind IPv6 trusted proxies' do
      v6 = Otto::Security::Config.new.tap { |cfg| cfg.add_trusted_proxy('fd00::/8') }
      env = {
        'REMOTE_ADDR' => 'fd00::1',
        'HTTP_X_FORWARDED_FOR' => '2001:db8::bad, 2001:db8::7, fd00::9, fd00::8',
      }

      expect(described_class.resolve_client_ip(env, v6)).to eq('2001:db8::7')
    end

    it 'resolves nothing when the walk reaches an entry that is not an address' do
      # A proxy that hides the client appends a token such as "unknown".
      # Everything left of it is client supplied, and the proxy is not the
      # client, so neither 9.9.9.9 nor REMOTE_ADDR is an answer.
      expect(resolve('HTTP_X_FORWARDED_FOR' => '9.9.9.9, unknown')).to be_nil
    end

    it 'resolves nothing when an invalid entry sits right of trusted hops' do
      expect(resolve('HTTP_X_FORWARDED_FOR' => '203.0.113.50, unknown, 10.0.0.9')).to be_nil
    end

    it 'resolves nothing when no entry is a valid address' do
      expect(resolve('HTTP_X_FORWARDED_FOR' => 'garbage, not-an-ip')).to be_nil
    end

    it 'treats an empty entry as invalid, trailing included' do
      # A trailing comma leaves an empty last entry, which only the proxy tier
      # can write. It must stop the walk like any other invalid entry.
      expect(resolve('HTTP_X_FORWARDED_FOR' => '203.0.113.50,')).to be_nil
      expect(resolve('HTTP_X_FORWARDED_FOR' => '203.0.113.50, ')).to be_nil
      expect(resolve('HTTP_X_FORWARDED_FOR' => '203.0.113.50, , 10.0.0.9')).to be_nil
    end

    it 'ignores empty entries left of the resolved address' do
      # Client supplied, so never reached.
      expect(resolve('HTTP_X_FORWARDED_FOR' => ',, 203.0.113.50')).to eq('203.0.113.50')
      expect(resolve('HTTP_X_FORWARDED_FOR' => '9.9.9.9,, 203.0.113.50, 10.0.0.9')).to eq('203.0.113.50')
    end

    it 'treats a range as invalid instead of resolving it' do
      # IPAddr.new parses "203.0.113.9/0" as 0.0.0.0/0; as a client IP that
      # became 0.0.0.0, and ip_match(['0.0.0.0/0']) was true.
      expect(resolve('HTTP_X_FORWARDED_FOR' => '9.9.9.9, 203.0.113.9/0')).to be_nil
      expect(resolve('HTTP_X_REAL_IP' => '203.0.113.9/32')).to be_nil
    end

    it 'resolves nothing when the single-valued fallback header is not an address' do
      expect(resolve('HTTP_X_REAL_IP' => 'unknown')).to be_nil
    end

    it 'still falls back to REMOTE_ADDR when every entry is a trusted proxy' do
      expect(resolve('HTTP_X_FORWARDED_FOR' => '10.0.0.7, 10.0.0.8')).to eq('10.0.0.1')
    end

    it 'does not append X-Real-IP or X-Client-IP to the X-Forwarded-For chain' do
      headers = {
        'HTTP_X_FORWARDED_FOR' => '10.0.0.9',
        'HTTP_X_REAL_IP' => '9.9.9.9',
        'HTTP_X_CLIENT_IP' => '8.8.8.8',
      }

      expect(resolve(headers)).to eq('10.0.0.1')
    end

    it 'reads a single-valued header only when X-Forwarded-For is absent or blank' do
      expect(resolve('HTTP_X_REAL_IP' => '203.0.113.7')).to eq('203.0.113.7')
      expect(resolve('HTTP_X_FORWARDED_FOR' => ' ', 'HTTP_X_REAL_IP' => '203.0.113.7')).to eq('203.0.113.7')
    end

    it 'reads X-Client-IP only when X-Real-IP is absent too' do
      expect(resolve('HTTP_X_REAL_IP' => '10.0.0.9', 'HTTP_X_CLIENT_IP' => '9.9.9.9')).to eq('10.0.0.1')
      expect(resolve('HTTP_X_CLIENT_IP' => '203.0.113.8')).to eq('203.0.113.8')
    end

    describe 'through an Otto application' do
      let(:captured) { {} }
      let(:otto) do
        sink = captured
        routes_file = create_test_routes_file('xff_rightmost.txt', ['GET /probe &probe'])
        Otto.new(routes_file, trusted_proxies: ['10.0.0.0/8'], lambda_handlers: {
                   'probe' => ->(req, _res, _extra) { sink[:env] = req.env },
                 })
      end

      it 'resolves and matches the address the proxy appended, not the forged one' do
        env = Rack::MockRequest.env_for('/probe', 'REMOTE_ADDR' => '10.0.0.5',
                                                  'HTTP_X_FORWARDED_FOR' => '1.2.3.4, 203.0.113.9')

        otto.call(env)

        expect(captured[:env]['otto.client_ip']).to eq('203.0.113.0')
        expect(captured[:env]['otto.ip_match'].call(['203.0.113.0/24'])).to be(true)
        expect(captured[:env]['otto.ip_match'].call(['1.2.3.0/24'])).to be(false)
      end
    end

    describe 'Otto::Request#client_ipaddress without the middleware' do
      it 'resolves the rightmost untrusted entry' do
        env = Rack::MockRequest.env_for('/', 'REMOTE_ADDR' => '10.0.0.1',
                                             'HTTP_X_FORWARDED_FOR' => '9.9.9.9, 203.0.113.50')
        req = Otto::Request.new(env)
        allow(req).to receive(:otto_security_config).and_return(config)

        expect(req.client_ipaddress).to eq('203.0.113.50')
      end
    end

    describe 'Otto::Request#client_ipaddress after the middleware found no client IP' do
      it 'keeps the verdict instead of re-resolving to the proxy' do
        # The middleware deleted the forwarded headers, so re-resolving would
        # see only the trusted peer and return it as the client.
        env = Rack::MockRequest.env_for('/', 'REMOTE_ADDR' => '10.0.0.1',
                                             'HTTP_X_FORWARDED_FOR' => '203.0.113.50, unknown')
        Otto::Testing.resolve_client_ip!(env, config)
        req = Otto::Request.new(env)
        allow(req).to receive(:otto_security_config).and_return(config)

        expect(req.client_ipaddress).to be_nil
      end

      it 'keeps Otto::Request#ip on the connecting peer so rate limiters still get a key' do
        # client_ipaddress is nil, but req.ip stays a String: rack-attack
        # skips a throttle whose discriminator is nil, so a nil req.ip would
        # exempt every request whose proxy hides the client from rate limits.
        env = Rack::MockRequest.env_for('/', 'REMOTE_ADDR' => '10.0.0.1',
                                             'HTTP_X_FORWARDED_FOR' => '203.0.113.50, unknown')
        Otto::Testing.resolve_client_ip!(env, config)
        req = Otto::Request.new(env)
        allow(req).to receive(:otto_security_config).and_return(config)

        expect(req.client_ipaddress).to be_nil
        expect(req.ip).to eq('10.0.0.1')
        expect(Rack::Request.new(env).ip).to eq('10.0.0.1')
      end

      it 'resolves normally when otto.ip_match was set without the middleware' do
        # otto.peer_relayed is written by every middleware pass; a stubbed
        # capability without it is not a verdict.
        env = Rack::MockRequest.env_for('/', 'REMOTE_ADDR' => '10.0.0.1',
                                             'HTTP_X_FORWARDED_FOR' => '9.9.9.9, 203.0.113.50',
                                             'otto.ip_match' => ->(_cidrs) { true })
        req = Otto::Request.new(env)
        allow(req).to receive(:otto_security_config).and_return(config)

        expect(req.client_ipaddress).to eq('203.0.113.50')
      end
    end
  end
end
