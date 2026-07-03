# spec/otto/security/csp_emission_integration_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

# End-to-end coverage of Otto#enable_csp_emission!: a full Otto instance with a
# routes file, exercised through Rack::Test, proving the EmitMiddleware backstop
# applies a nonce CSP for HTML responses whose request consumed a nonce, stays
# silent for those that did not (emit-if-consumed), and never clobbers a policy
# a route already set.
RSpec.describe 'Otto CSP emission (integration)' do
  include Rack::Test::Methods

  # Controller instantiated as new(req, res); the action runs with no arguments.
  class CspEmitApp
    def initialize(req, res)
      @req = req
      @res = res
    end

    # A "view" that stamps the framework-owned nonce onto an inline script.
    def with_nonce
      @res['content-type'] = 'text/html; charset=utf-8'
      @res.write(%(<script nonce="#{@req.csp_nonce}">1</script>))
    end

    # An HTML response that never touches the nonce.
    def without_nonce
      @res['content-type'] = 'text/html; charset=utf-8'
      @res.write('<p>no nonce</p>')
    end

    # A JSON response (non-HTML).
    def json
      @res['content-type'] = 'application/json'
      @res.write('{"ok":true}')
    end

    # A route that sets its own CSP; the backstop must defer to it.
    def preset_csp
      @res['content-type'] = 'text/html; charset=utf-8'
      @res['content-security-policy'] = "default-src 'self'"
      @res.write('preset')
    end
  end

  let(:routes_file) do
    file = Tempfile.new(['csp_emit_routes', '.txt'])
    file.write(<<~ROUTES)
      GET /with CspEmitApp#with_nonce
      GET /without CspEmitApp#without_nonce
      GET /json CspEmitApp#json
      GET /preset CspEmitApp#preset_csp
    ROUTES
    file.flush
    file
  end

  let(:otto) do
    instance = Otto.new(routes_file.path)
    instance.enable_csp_with_nonce!
    instance.enable_csp_emission!
    instance
  end

  def app
    otto
  end

  after { routes_file.close! }

  it 'registers the emit middleware in the stack' do
    expect(otto.middleware_stack.map(&:name)).to include('Otto::Security::CSP::EmitMiddleware')
  end

  it 'emits a nonce CSP whose nonce matches the one the view stamped' do
    get '/with'
    csp = last_response.headers['content-security-policy']
    body_nonce = last_response.body[/nonce="([^"]+)"/, 1]

    expect(csp).to include("script-src 'nonce-#{body_nonce}'")
  end

  it 'stays silent for an HTML response that never consumed a nonce' do
    get '/without'
    expect(last_response.headers).not_to have_key('content-security-policy')
  end

  it 'stays silent for a non-HTML (JSON) response' do
    get '/json'
    expect(last_response.headers).not_to have_key('content-security-policy')
  end

  it 'defers to a CSP the route already set (never clobbers)' do
    get '/preset'
    expect(last_response.headers['content-security-policy']).to eq("default-src 'self'")
  end

  it 'is inert when emission is enabled but nonce-CSP is not' do
    instance = Otto.new(routes_file.path)
    instance.enable_csp_emission! # no enable_csp_with_nonce!
    get_env = Rack::MockRequest.env_for('/with')
    _status, headers, = instance.call(get_env)
    expect(headers).not_to have_key('content-security-policy')
  end
end
