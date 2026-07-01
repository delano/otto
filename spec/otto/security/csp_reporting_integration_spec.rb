# spec/otto/security/csp_reporting_integration_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tempfile'

# End-to-end coverage of Otto#enable_csp_reporting!: a full Otto instance with a
# routes file, exercised through Rack::Test, proving the report endpoint is
# received, parsed, dispatched, and answered 204 — and that it short-circuits
# ahead of CSRF so browsers can POST without a token.
RSpec.describe 'Otto CSP violation reporting (integration)' do
  include Rack::Test::Methods

  # A trivial controller for the routes file. Otto instantiates it as
  # new(req, res) and invokes the action with no arguments.
  class CspIntegrationApp
    def initialize(_req, res)
      @res = res
    end

    def index
      @res.write('ok')
    end

    def submit
      @res.write('submitted')
    end
  end

  let(:routes_file) do
    file = Tempfile.new(['csp_routes', '.txt'])
    file.write("GET / CspIntegrationApp#index\nPOST /submit CspIntegrationApp#submit\n")
    file.flush
    file
  end

  let(:violations) { [] }

  # Build an Otto instance, choosing the order in which CSRF and CSP reporting
  # are enabled. The report bypass of CSRF MUST hold either way.
  def build_otto(reporting_first: false)
    instance = Otto.new(routes_file.path)
    if reporting_first
      instance.enable_csp_reporting!('/_/csp-report') { |report| violations << report }
      instance.enable_csrf_protection!
    else
      instance.enable_csrf_protection!
      instance.enable_csp_reporting!('/_/csp-report') { |report| violations << report }
    end
    instance
  end

  let(:otto) { build_otto }

  # Rack::Test's `app`.
  def app
    otto
  end

  after { routes_file.close! }

  it 'registers the report middleware in the stack' do
    names = otto.middleware_stack.map(&:name)
    expect(names).to include('Otto::Security::CSP::ReportMiddleware')
  end

  # The CSRF bypass must be order-independent (ReportMiddleware is pinned
  # outermost), so a tokenless report POST returns 204 whether reporting is
  # enabled before OR after CSRF.
  [false, true].each do |reporting_first|
    order_desc = reporting_first ? 'reporting enabled BEFORE csrf' : 'reporting enabled AFTER csrf'

    context "when #{order_desc}" do
      let(:otto) { build_otto(reporting_first: reporting_first) }

      it 'answers a tokenless report POST with 204 and dispatches the violation' do
        body = { 'csp-report' => { 'violated-directive' => 'script-src' } }.to_json
        post '/_/csp-report', body, 'CONTENT_TYPE' => 'application/csp-report'

        expect(last_response.status).to eq(204)
        expect(violations.length).to eq(1)
        expect(violations.first.violated_directive).to eq('script-src')
      end

      it 'still rejects a tokenless POST to a normal CSRF-protected route' do
        post '/submit', 'x=1'
        expect(last_response.status).to eq(403)
      end
    end
  end

  it 'receives a legacy report, dispatches it, and answers 204 (no CSRF token needed)' do
    body = { 'csp-report' => { 'violated-directive' => 'style-src', 'blocked-uri' => 'inline' } }.to_json
    post '/_/csp-report', body, 'CONTENT_TYPE' => 'application/csp-report'

    expect(last_response.status).to eq(204)
    expect(last_response.body).to eq('')
    expect(violations.length).to eq(1)
    expect(violations.first.violated_directive).to eq('style-src')
  end

  it 'receives a Reporting API batch and dispatches each violation' do
    body = [
      { 'type' => 'csp-violation', 'body' => { 'effectiveDirective' => 'img-src', 'blockedURL' => 'https://cdn/x' } },
      { 'type' => 'csp-violation', 'body' => { 'effectiveDirective' => 'font-src' } },
    ].to_json
    post '/_/csp-report', body, 'CONTENT_TYPE' => 'application/reports+json'

    expect(last_response.status).to eq(204)
    expect(violations.map(&:effective_directive)).to contain_exactly('img-src', 'font-src')
  end

  it 'answers 204 for malformed input without dispatching' do
    post '/_/csp-report', '{not json', 'CONTENT_TYPE' => 'application/csp-report'

    expect(last_response.status).to eq(204)
    expect(violations).to be_empty
  end

  it 'answers 204 and does not parse an oversized body' do
    big = "{\"csp-report\":{\"pad\":\"#{'x' * (Otto::Security::CSP::ReportMiddleware::MAX_BODY_BYTES + 50)}\"}}"
    post '/_/csp-report', big, 'CONTENT_TYPE' => 'application/csp-report'

    expect(last_response.status).to eq(204)
    expect(violations).to be_empty
  end

  it 'passes a GET to the report path through to routing (only POST is intercepted)' do
    get '/_/csp-report'
    expect(last_response.status).to eq(404)
  end

  context 'with a static policy and legacy reporting enabled' do
    let(:otto) do
      instance = Otto.new(routes_file.path)
      instance.enable_csp!("default-src 'self'")
      instance.enable_csp_reporting!('/_/csp-report') { |report| violations << report }
      instance
    end

    it 'carries the report-uri directive in the emitted policy on ordinary responses' do
      get '/'
      expect(last_response['content-security-policy']).to include('report-uri /_/csp-report')
    end
  end

  context 'with a static policy and modern (Reporting API) reporting enabled' do
    let(:endpoint) { 'https://example.com/_/csp-report' }
    let(:otto) do
      instance = Otto.new(routes_file.path)
      instance.enable_csp!("default-src 'self'")
      instance.enable_csp_reporting!('/_/csp-report', endpoint_url: endpoint) { |report| violations << report }
      instance
    end

    it 'emits both report-uri and report-to plus a Reporting-Endpoints header' do
      get '/'
      csp = last_response['content-security-policy']
      expect(csp).to include('report-uri /_/csp-report')
      expect(csp).to include('report-to otto-csp')
      expect(last_response['reporting-endpoints']).to eq(%(otto-csp="#{endpoint}"))
    end

    it 'still receives and dispatches a modern reports+json POST' do
      body = [{ 'type' => 'csp-violation', 'body' => { 'effectiveDirective' => 'img-src' } }].to_json
      post '/_/csp-report', body, 'CONTENT_TYPE' => 'application/reports+json'

      expect(last_response.status).to eq(204)
      expect(violations.map(&:effective_directive)).to eq(['img-src'])
    end
  end
end
