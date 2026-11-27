# spec/otto/mcp/origin_guard_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::MCP::OriginGuard do
  subject(:guard) { described_class.new(app, '/mcp', ['https://app.example.com']) }

  let(:reached) { [] }
  let(:app) do
    lambda { |env|
      reached << env['PATH_INFO']
      [200, {}, ['ok']]
    }
  end

  def request(path: '/mcp', origin: nil, host: 'mcp.example.com')
    env = Rack::MockRequest.env_for(path, method: 'POST', 'HTTP_HOST' => host)
    env['HTTP_ORIGIN'] = origin if origin
    guard.call(env)
  end

  it 'passes a request with no Origin header' do
    expect(request.first).to eq(200)
  end

  it 'passes a listed origin, compared without regard to case' do
    expect(request(origin: 'https://app.example.com').first).to eq(200)
    expect(request(origin: 'HTTPS://App.Example.com').first).to eq(200)
  end

  {
    'an unlisted origin' => 'https://evil.example',
    'a listed host on another scheme' => 'http://app.example.com',
    'a listed host on another port' => 'https://app.example.com:8443',
    'an opaque origin' => 'null',
    'an empty Origin header' => '',
  }.each do |label, origin|
    it "answers 403 to #{label} without reaching the app" do
      status, headers, body = request(origin: origin)

      expect(status).to eq(403)
      expect(headers['content-type']).to eq('application/json')
      expect(JSON.parse(body.first)).to eq(
        'jsonrpc' => '2.0',
        'error' => { 'code' => 403, 'message' => 'Forbidden', 'data' => 'Origin not allowed' }
      )
      expect(reached).to be_empty
    end
  end

  it 'refuses an origin that equals the Host header, as a rebound page would send' do
    expect(request(origin: 'https://rebound.example', host: 'rebound.example').first).to eq(403)
  end

  it 'answers 403 to an origin with bytes that are invalid in its encoding' do
    expect(request(origin: (+"https://app.example.com\xFF").force_encoding(Encoding::UTF_8)).first).to eq(403)
    expect(request(origin: "https://app.example.com\xFF".b).first).to eq(403)
  end

  it 'does not echo the origin it refuses' do
    expect(request(origin: 'https://evil.example')[2].first).not_to include('evil.example')
  end

  it 'leaves other paths alone, including one that shares the prefix' do
    expect(request(path: '/mcp-admin', origin: 'https://evil.example').first).to eq(200)
    expect(request(path: '/', origin: 'https://evil.example').first).to eq(200)
  end

  it 'matches the endpoint as the router does, with or without a trailing slash' do
    expect(request(path: '/mcp/', origin: 'https://evil.example').first).to eq(403)
  end

  it 'refuses every origin when the list is empty' do
    closed = described_class.new(app, '/mcp', [])
    env    = Rack::MockRequest.env_for('/mcp', method: 'POST', 'HTTP_ORIGIN' => 'https://app.example.com')

    expect(closed.call(env).first).to eq(403)
  end
end
