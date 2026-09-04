# spec/otto/security/authentication/api_key_fail_closed_integration_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# End-to-end regression coverage for issue #256: APIKeyStrategy must fail
# closed. These drive a real Otto app (routes file, RouteAuthWrapper, response
# builder) rather than calling the strategy directly, so they also pin the
# status codes a client actually sees.
# rubocop:disable-next RSpec/DescribeClass -- end-to-end spec spans Otto, the
# route auth wrapper, and the strategy; no single class is under test.
RSpec.describe 'API key authentication end-to-end (issue #256)' do
  include OttoTestHelpers

  let(:api_key) { 'valid-key-256' }

  let(:apikey_strategy) do
    Otto::Security::Authentication::Strategies::APIKeyStrategy.new(api_keys: [api_key])
  end

  def get(otto, headers: {})
    otto.call(mock_rack_env(path: '/api/data', headers: headers))
  end

  describe 'single-strategy route' do
    let(:otto) do
      app = create_minimal_otto(['GET /api/data TestApp.index auth=apikey response=json'])
      app.add_auth_strategy('apikey', apikey_strategy)
      app
    end

    it 'returns 401 when no API key is presented' do
      status, = get(otto)
      expect(status).to eq(401)
    end

    it 'returns 401 for an incorrect API key' do
      status, = get(otto, headers: { 'X-API-Key' => 'wrong-key-256' })
      expect(status).to eq(401)
    end

    it 'returns 401 for an empty API key header' do
      status, = get(otto, headers: { 'X-API-Key' => '' })
      expect(status).to eq(401)
    end

    it 'returns 401 for an array-valued api_key query parameter' do
      status, = otto.call(mock_rack_env(path: '/api/data?api_key[]=valid-key-256'))
      expect(status).to eq(401)
    end

    it 'returns 200 for the configured API key' do
      status, _headers, body = get(otto, headers: { 'X-API-Key' => api_key })
      expect(status).to eq(200)
      expect(body.join).to include('Hello World')
    end
  end

  describe 'multi-strategy OR chain with an anonymous-capable strategy' do
    let(:otto) do
      app = create_minimal_otto(['GET /api/data TestApp.index auth=apikey,noauth response=json'])
      app.add_auth_strategy('apikey', apikey_strategy)
      app.add_auth_strategy('noauth', Otto::Security::Authentication::Strategies::NoAuthStrategy.new)
      app
    end

    it 'falls through to the anonymous strategy when no key is presented' do
      status, = get(otto)
      expect(status).to eq(200)
    end

    it 'does not fall through to the anonymous strategy for a rejected key' do
      status, _headers, body = get(otto, headers: { 'X-API-Key' => 'wrong-key-256' })
      expect(status).to eq(401)
      expect(body.join).to include('Invalid API key')
    end
  end
end
