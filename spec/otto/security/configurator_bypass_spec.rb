# spec/otto/security/configurator_bypass_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

# Regression coverage for the silent middleware bypass: security middleware
# enabled through the documented `otto.security.*` Configurator surface (and the
# `configure` facade) after `Otto.new` used to register in the stack but never
# enter the running request chain, because @app was built once and never rebuilt.
# These specs drive real requests and assert the control actually EXECUTES —
# list membership alone is not enough (it was already true while the control was
# bypassed). See Otto#initialize_core_state (the on_change rebuild wiring).
RSpec.describe 'Security Configurator middleware takes effect (bypass regression)' do
  include Rack::Test::Methods

  class BypassApp
    def initialize(req, res)
      @res = res
    end

    def submit
      @res.write('ok')
    end
  end

  let(:routes_file) do
    file = Tempfile.new(['bypass_routes', '.txt'])
    file.write("POST /submit BypassApp#submit\n")
    file.flush
    file
  end

  after { routes_file.close! }

  def app
    @otto
  end

  # Enable CSRF via each documented surface AFTER construction and assert a
  # tokenless POST is actually rejected (403) — proof the middleware runs.
  {
    'otto.enable_csrf_protection! (Core)'          => ->(o) { o.enable_csrf_protection! },
    'otto.security.enable_csrf_protection!'        => ->(o) { o.security.enable_csrf_protection! },
    'otto.security.configure(csrf_protection: true)' => ->(o) { o.security.configure(csrf_protection: true) },
  }.each do |surface, enable|
    context "when CSRF is enabled via #{surface}" do
      before do
        @otto = Otto.new(routes_file.path)
        enable.call(@otto)
      end

      it 'enforces CSRF on a tokenless unsafe request (middleware is in the running chain)' do
        post '/submit', 'x=1'
        expect(last_response.status).to eq(403)
      end

      it 'reports the config as enabled and the middleware as present' do
        expect(@otto.security_config.csrf_enabled?).to be true
        expect(@otto.middleware.includes?(Otto::Security::Middleware::CSRFMiddleware)).to be true
      end
    end
  end

  context 'when CSP reporting is enabled via the Configurator after construction' do
    let(:violations) { [] }

    before do
      @otto = Otto.new(routes_file.path)
      @otto.enable_csrf_protection!
      @otto.security.enable_csp_reporting!('/_/csp-report') { |report| violations << report }
    end

    it 'receives a tokenless report POST through the running chain (204 + dispatch)' do
      body = { 'csp-report' => { 'violated-directive' => 'script-src' } }.to_json
      post '/_/csp-report', body, 'CONTENT_TYPE' => 'application/csp-report'

      expect(last_response.status).to eq(204)
      expect(violations.map(&:violated_directive)).to eq(['script-src'])
    end
  end

  context 'when middleware is added via the raw stack after construction' do
    it 'rebuilds @app so the newly added middleware executes' do
      otto = Otto.new(routes_file.path)
      executed = false
      spy = Class.new do
        define_method(:initialize) { |app, *| @app = app }
        define_method(:call) do |env|
          executed = true
          @app.call(env)
        end
      end

      otto.middleware.add(spy)
      Rack::MockRequest.new(otto).post('/submit', params: { 'x' => '1' })
      expect(executed).to be true
    end
  end
end
