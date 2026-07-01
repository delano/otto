# spec/otto/security/csp/report_middleware_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'stringio'

RSpec.describe Otto::Security::CSP::ReportMiddleware do
  let(:downstream_called) { [] }
  let(:app) do
    lambda do |env|
      downstream_called << env['PATH_INFO']
      [200, { 'content-type' => 'text/plain' }, ['downstream']]
    end
  end

  let(:config) { Otto::Security::Config.new }
  let(:received) { [] }
  let(:middleware) { described_class.new(app, config) }

  # Build a Rack env for a POST with a body.
  def post_env(path:, body:, content_type: 'application/csp-report')
    {
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => path,
      'CONTENT_TYPE' => content_type,
      'rack.input' => StringIO.new(body.to_s),
    }
  end

  before do
    config.csp_report_uri = '/_/csp-report'
    config.on_csp_violation { |report| received << report }
  end

  describe 'inert until configured' do
    it 'passes through when no report URI is set' do
      unconfigured = Otto::Security::Config.new
      mw = described_class.new(app, unconfigured)

      env = post_env(path: '/_/csp-report', body: '{"csp-report":{}}')
      status, = mw.call(env)

      expect(status).to eq(200)
      expect(downstream_called).to eq(['/_/csp-report'])
    end
  end

  describe 'request scoping' do
    it 'passes non-matching paths through untouched' do
      env = post_env(path: '/api/submit', body: '{}')
      status, = middleware.call(env)

      expect(status).to eq(200)
      expect(downstream_called).to eq(['/api/submit'])
      expect(received).to be_empty
    end

    it 'passes non-POST requests to the report path through untouched' do
      env = post_env(path: '/_/csp-report', body: '').merge('REQUEST_METHOD' => 'GET')
      status, = middleware.call(env)

      expect(status).to eq(200)
      expect(downstream_called).to eq(['/_/csp-report'])
      expect(received).to be_empty
    end

    it 'does NOT swallow downstream errors on pass-through requests' do
      # The receiver runs outermost; its rescue must guard report handling only.
      # A downstream error on an ordinary request must propagate to Otto's normal
      # error handling, not be masked as a silent 204.
      boom = ->(_env) { raise StandardError, 'downstream boom' }
      mw = described_class.new(boom, config)

      expect { mw.call(post_env(path: '/api/submit', body: '{}')) }
        .to raise_error(StandardError, 'downstream boom')
    end
  end

  describe 'receiving reports' do
    it 'returns 204 with an empty body and never calls downstream' do
      body = { 'csp-report' => { 'violated-directive' => 'script-src' } }.to_json
      status, headers, resp_body = middleware.call(post_env(path: '/_/csp-report', body: body))

      expect(status).to eq(204)
      expect(resp_body).to eq([])
      expect(downstream_called).to be_empty
      expect(headers).to eq({})
    end

    it 'dispatches a legacy report to the callback' do
      body = { 'csp-report' => { 'violated-directive' => 'style-src', 'blocked-uri' => 'inline' } }.to_json
      middleware.call(post_env(path: '/_/csp-report', body: body))

      expect(received.length).to eq(1)
      expect(received.first.violated_directive).to eq('style-src')
      expect(received.first.blocked_uri).to eq('inline')
    end

    it 'dispatches every report in a Reporting API batch' do
      body = [
        { 'type' => 'csp-violation', 'body' => { 'effectiveDirective' => 'img-src' } },
        { 'type' => 'csp-violation', 'body' => { 'effectiveDirective' => 'font-src' } },
      ].to_json
      middleware.call(post_env(path: '/_/csp-report', body: body, content_type: 'application/reports+json'))

      expect(received.map(&:effective_directive)).to contain_exactly('img-src', 'font-src')
    end
  end

  describe 'hardening' do
    it 'skips an oversized body without parsing (still 204, no callback)' do
      big = "{\"csp-report\":{\"pad\":\"#{'x' * (described_class::MAX_BODY_BYTES + 100)}\"}}"
      status, = middleware.call(post_env(path: '/_/csp-report', body: big))

      expect(status).to eq(204)
      expect(received).to be_empty
    end

    it 'accepts a body exactly at the cap' do
      inner = { 'csp-report' => { 'violated-directive' => 'script-src' } }
      json = inner.to_json
      # Pad to exactly MAX_BODY_BYTES with a filler key.
      pad = described_class::MAX_BODY_BYTES - json.bytesize - ',"pad":""'.bytesize
      padded = { 'csp-report' => { 'violated-directive' => 'script-src' }, 'pad' => 'x' * [pad, 0].max }.to_json
      padded = padded.byteslice(0, described_class::MAX_BODY_BYTES) if padded.bytesize > described_class::MAX_BODY_BYTES

      status, = middleware.call(post_env(path: '/_/csp-report', body: padded))
      expect(status).to eq(204)
    end

    it 'returns 204 for malformed JSON without invoking the callback' do
      status, = middleware.call(post_env(path: '/_/csp-report', body: '{not json'))

      expect(status).to eq(204)
      expect(received).to be_empty
    end

    it 'returns 204 for an empty body' do
      status, = middleware.call(post_env(path: '/_/csp-report', body: ''))

      expect(status).to eq(204)
      expect(received).to be_empty
    end

    it 'returns 204 even when there is no rack.input' do
      env = { 'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/_/csp-report', 'CONTENT_TYPE' => 'application/csp-report' }
      status, = middleware.call(env)

      expect(status).to eq(204)
      expect(received).to be_empty
    end

    it 'never lets a throwing callback surface to the client' do
      config.on_csp_violation { |_report| raise 'boom in app callback' }
      body = { 'csp-report' => { 'violated-directive' => 'script-src' } }.to_json

      status, = nil
      expect { status, = middleware.call(post_env(path: '/_/csp-report', body: body)) }.not_to raise_error
      expect(status).to eq(204)
    end

    it 'returns a fresh, mutable header hash per response (safe for servers that mutate it)' do
      body = { 'csp-report' => { 'violated-directive' => 'script-src' } }.to_json
      _status, headers, = middleware.call(post_env(path: '/_/csp-report', body: body))

      expect(headers).not_to be_frozen
      expect { headers['x-test'] = '1' }.not_to raise_error
    end
  end

  describe 'default config' do
    it 'is inert (pass-through) when constructed without a config' do
      mw = described_class.new(app)
      env = post_env(path: '/_/csp-report', body: '{}')
      status, = mw.call(env)

      expect(status).to eq(200)
    end
  end
end
