# spec/otto/mcp/server_register_resource_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# A resource declared in the routes file (MCP uri Class.method) is served by a
# class method. A handler that takes one argument receives the Rack env of the
# MCP request, so it can check permissions per request as a tool handler can.
# A zero-argument handler is still called with no arguments.
RSpec.describe Otto::MCP::Server, '#register_resource' do
  include_context 'with rack attack isolation'

  let(:otto) do
    routes = [
      'GET /r MCP plain ResourceEnvApp.plain',
      'GET /r MCP whoami ResourceEnvApp.whoami',
      'GET /r MCP optional ResourceEnvApp.optional',
      'GET /r MCP too_many ResourceEnvApp.too_many',
      'GET /r MCP keyword ResourceEnvApp.keyword',
    ]
    Otto.new(create_test_routes_file('mcp_resources.txt', routes),
      mcp_enabled: true, mcp_allow_unauthenticated: true, mcp_rate_limiting: false)
  end

  before do
    stub_const('ResourceEnvApp', Module.new do
      def self.plain = 'plain resource'
      def self.whoami(env) = "caller #{env['HTTP_X_CALLER']}"
      def self.optional(env = nil) = "optional #{env && env['HTTP_X_CALLER']}"
      def self.too_many(_env, _extra) = 'unreachable'
      def self.keyword(env:) = "keyword #{env}"
    end)
  end

  def read(uri)
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri: uri })
    env  = Rack::MockRequest.env_for('/_mcp', method: 'POST', input: body,
      'CONTENT_TYPE' => 'application/json', 'HTTP_X_CALLER' => 'ada')
    status, _headers, response = otto.call(env)
    [status, JSON.parse(response.to_a.join)]
  end

  def text_of(body)
    body.dig('result', 'contents', 0, 'text')
  end

  it 'calls a zero-argument handler with no arguments' do
    status, body = read('plain')

    expect(status).to eq(200)
    expect(text_of(body)).to eq('plain resource')
  end

  it 'passes the Rack env of the MCP request to a handler that takes one argument' do
    status, body = read('whoami')

    expect(status).to eq(200)
    expect(text_of(body)).to eq('caller ada')
  end

  it 'passes the Rack env to a handler whose one argument is optional' do
    expect(text_of(read('optional').last)).to eq('optional ada')
  end

  it 'fails the read for a handler that requires two arguments' do
    status, body = read('too_many')

    expect(status).to eq(500)
    expect(body.dig('error', 'code')).to eq(-32_603)
  end

  it 'fails the read for a handler that requires a keyword argument' do
    status, body = read('keyword')

    expect(status).to eq(500)
    expect(body.dig('error', 'code')).to eq(-32_603)
  end
end
