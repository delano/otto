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

    it 'does not read past an entry that is not an address' do
      # A proxy that hides the client (for example Squid with forwarded_for off)
      # appends "unknown". Everything left of it is client supplied.
      expect(resolve('HTTP_X_FORWARDED_FOR' => '9.9.9.9, unknown')).to eq('10.0.0.1')
    end

    it 'falls back to REMOTE_ADDR when no entry is a valid address' do
      expect(resolve('HTTP_X_FORWARDED_FOR' => 'garbage, not-an-ip')).to eq('10.0.0.1')
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
  end
end
