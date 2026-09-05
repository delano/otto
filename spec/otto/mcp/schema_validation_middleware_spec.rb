# spec/otto/mcp/schema_validation_middleware_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::SchemaValidationMiddleware do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['OK']] } }

  # Missing "id", and a bad jsonrpc version: rejected by the MCP request schema.
  let(:invalid_body) { JSON.generate({ jsonrpc: '1.0', method: 'tools/list' }) }

  before do
    Otto::MCP::Validator.ensure_available!
  rescue Otto::OptionalDependencyError => e
    skip e.message
  end

  def post(path, endpoint:, body: invalid_body)
    env = Rack::MockRequest.env_for(path, method: 'POST', input: body, 'CONTENT_TYPE' => 'application/json')
    env['otto.mcp_http_endpoint'] = endpoint
    described_class.new(app).call(env)
  end

  it 'rejects an invalid request on the endpoint' do
    status, headers, body = post('/a', endpoint: '/a')

    expect(status).to eq(400)
    expect(headers['content-type']).to eq('application/json')
    expect(JSON.parse(body.join).dig('error', 'message')).to eq('Invalid Request')
  end

  # The router dispatches the endpoint by exact literal match; a prefix match
  # here parsed and rejected bodies posted to /admin beside an endpoint at /a.
  it 'leaves a sibling path that shares the endpoint prefix alone' do
    expect(post('/admin', endpoint: '/a').first).to eq(200)
    expect(post('/a/b', endpoint: '/a').first).to eq(200)
  end

  it 'validates only the root when the endpoint is the root' do
    expect(post('/anything', endpoint: '/').first).to eq(200)
    expect(post('/', endpoint: '/').first).to eq(400)
  end

  it 'validates the trailing-slash form the router dispatches to the endpoint' do
    expect(post('/a/', endpoint: '/a').first).to eq(400)
  end
end
