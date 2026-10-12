# spec/otto/security/csrf_cache_control_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# A response that carries the CSRF binding cookie, or a token CSRFMiddleware
# injected, is meant for one client. RFC 9111, section 7.3: "Note that the
# Set-Cookie response header field [COOKIE] does not inhibit caching; a
# cacheable response with a Set-Cookie header field can be (and often is)
# used to satisfy subsequent requests to caches." Without Cache-Control, a
# shared cache that stores such a response hands one client's binding, or a
# token bound to one client's session, to others. CSRFMiddleware marks those
# responses Cache-Control: private unless the app set Cache-Control or
# Expires itself.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'CSRF responses and shared caches' do
  include OttoTestHelpers

  let(:config) do
    Otto::Security::Config.new.tap do |c|
      c.enable_csrf_protection!
      c.csrf_secret = 'd' * 64
    end
  end

  let(:html) { '<html><head></head><body>form</body></html>' }

  def middleware_call(headers, body: [html], method: 'GET', cookie: nil, binding_id: nil)
    inner = lambda do |env|
      env['otto.csrf_binding'] = binding_id if binding_id
      [200, headers, body]
    end
    env = Rack::MockRequest.env_for('https://example.org/', method: method)
    env['HTTP_COOKIE'] = cookie if cookie
    Otto::Security::Middleware::CSRFMiddleware.new(inner, config).call(env)
  end

  def cookie_lines(headers)
    headers.select { |key, _value| key.casecmp?('set-cookie') }.values.flat_map { |value| Array(value) }
  end

  def cache_control_values(headers)
    headers.select { |key, _value| key.casecmp?('cache-control') }.values
  end

  describe 'an HTML response' do
    it 'is private when the binding cookie is set and the token injected' do
      _, headers, = middleware_call({ 'content-type' => 'text/html' })

      expect(cookie_lines(headers).grep(/\A__Host-otto_session=/).size).to eq(1)
      expect(headers['cache-control']).to eq('private')
    end

    # The binding comes from the request (here the binding cookie, or the
    # session store's id behind a session middleware), so no Set-Cookie is
    # sent, but the body still carries a token bound to this client.
    it 'is private when only the token is injected' do
      _, headers, body = middleware_call({ 'content-type' => 'text/html' }, cookie: '__Host-otto_session=hostbound')

      expect(cookie_lines(headers)).to be_empty
      expect(body.join).to include('<meta name="csrf-token"')
      expect(headers['cache-control']).to eq('private')
    end

    it 'is private when the binding cookie is set on a page without <head>' do
      _, headers, body = middleware_call({ 'content-type' => 'text/html' }, body: ['<p>no head</p>'])

      expect(body.join).not_to include('csrf-token')
      expect(cookie_lines(headers).grep(/\A__Host-otto_session=/).size).to eq(1)
      expect(headers['cache-control']).to eq('private')
    end

    it 'gets no Cache-Control when Otto neither set the cookie nor injected a token' do
      _, headers, = middleware_call({ 'content-type' => 'text/html' }, body: ['<p>no head</p>'],
                                                                       cookie: '__Host-otto_session=hostbound')

      expect(cache_control_values(headers)).to be_empty
    end

    it "keeps the app's Cache-Control" do
      _, headers, = middleware_call({ 'content-type' => 'text/html', 'cache-control' => 'no-store' })

      expect(headers['cache-control']).to eq('no-store')
    end

    # An explicit choice, even one that lets shared caches store the page,
    # is the app's to make.
    it "keeps an app's Cache-Control that allows shared caching" do
      _, headers, = middleware_call({ 'content-type' => 'text/html', 'cache-control' => 'public, max-age=60' })

      expect(headers['cache-control']).to eq('public, max-age=60')
    end

    it "adds no Cache-Control next to the app's Expires" do
      expires = 'Thu, 01 Jan 2037 00:00:00 GMT'
      _, headers, = middleware_call({ 'content-type' => 'text/html', 'expires' => expires })

      expect(cache_control_values(headers)).to be_empty
      expect(headers['expires']).to eq(expires)
    end

    it "copies rather than changes the app's frozen headers" do
      app_headers = { 'content-type' => 'text/html', 'content-length' => html.bytesize.to_s }.freeze

      _, headers, body = middleware_call(app_headers)

      expect(headers['cache-control']).to eq('private')
      expect(headers['content-length']).to eq(body.join.bytesize.to_s)
      expect(app_headers).to eq('content-type' => 'text/html', 'content-length' => html.bytesize.to_s)
    end

    # An app that returns the same headers object for every response would
    # otherwise carry one client's binding cookie into the next response.
    it 'does not carry one response\'s binding cookie into the next when the app shares its headers' do
      shared = { 'content-type' => 'text/html' }

      _, first, = middleware_call(shared)
      _, second, = middleware_call(shared)

      expect(cookie_lines(second).size).to eq(1)
      expect(cookie_lines(second)).not_to eq(cookie_lines(first))
      expect(shared).to eq('content-type' => 'text/html')
    end
  end

  describe 'a response that is not HTML' do
    let(:json) { { 'content-type' => 'application/json' } }

    it 'is private when the binding cookie is set' do
      _, headers, = middleware_call(json, body: ['{}'], binding_id: 'minted')

      expect(cookie_lines(headers)).to eq(['__Host-otto_session=minted; Path=/; HttpOnly; SameSite=Lax; Secure'])
      expect(headers['cache-control']).to eq('private')
    end

    it 'gets no Cache-Control without a binding to set' do
      _, headers, = middleware_call(json, body: ['{}'])

      expect(cache_control_values(headers)).to be_empty
    end

    it 'gets no Cache-Control on a response to an unsafe request' do
      _, headers, = middleware_call(json, body: ['{}'], method: 'POST', binding_id: 'minted')

      expect(cookie_lines(headers)).to be_empty
      expect(cache_control_values(headers)).to be_empty
    end

    it "keeps the app's Cache-Control" do
      _, headers, = middleware_call(json.merge('cache-control' => 'no-cache'), body: ['{}'], binding_id: 'minted')

      expect(headers['cache-control']).to eq('no-cache')
    end

    it "copies rather than changes the app's frozen headers" do
      app_headers = json.dup.freeze

      _, headers, = middleware_call(app_headers, body: ['{}'], binding_id: 'minted')

      expect(headers['cache-control']).to eq('private')
      expect(app_headers).to eq(json)
    end
  end

  # Rack 3 header names are lowercase, but a plain Hash from an older app
  # may spell them in mixed case. Rack::Headers folds case itself.
  describe 'header name case' do
    it "keeps a plain Hash's mixed-case Cache-Control without adding a second one" do
      _, headers, = middleware_call({ 'Content-Type' => 'text/html', 'Cache-Control' => 'no-store' })

      expect(headers).not_to have_key('cache-control')
      expect(headers['Cache-Control']).to eq('no-store')
    end

    it "keeps a plain Hash's mixed-case Expires" do
      _, headers, = middleware_call({ 'Content-Type' => 'text/html', 'Expires' => '0' })

      expect(cache_control_values(headers)).to be_empty
    end

    it 'adds cache-control in lowercase to a plain Hash with mixed-case names' do
      _, headers, = middleware_call({ 'Content-Type' => 'application/json' }, body: ['{}'], binding_id: 'minted')

      expect(headers['cache-control']).to eq('private')
    end

    it "keeps Rack::Headers' Cache-Control" do
      app_headers = Rack::Headers.new.merge!('Content-Type' => 'text/html', 'Cache-Control' => 'no-store')

      _, headers, = middleware_call(app_headers)

      expect(headers['cache-control']).to eq('no-store')
      expect(cache_control_values(headers)).to eq(['no-store'])
    end

    it 'marks frozen Rack::Headers private on a copy' do
      app_headers = Rack::Headers.new.merge!('Content-Type' => 'text/html').freeze

      _, headers, = middleware_call(app_headers)

      expect(headers['Cache-Control']).to eq('private')
      expect(app_headers).not_to have_key('cache-control')
    end
  end

  describe 'through Otto#call' do
    let(:otto) do
      handlers = {
        'page' => lambda do |_req, res, _extra|
          res['content-type'] = 'text/html'
          res.write('<html><head></head><body></body></html>')
        end,
        'no_cache_page' => lambda do |_req, res, _extra|
          res.no_cache!
          res['content-type'] = 'text/html'
          res.write('<html><head></head><body></body></html>')
        end,
        'plain' => lambda do |_req, res, _extra|
          res['content-type'] = 'text/plain'
          res.write('ok')
        end,
      }
      routes = create_test_routes_file('test_routes_csrf_cache_control.txt',
                                       ['GET /page &page', 'GET /no-cache &no_cache_page', 'GET /plain &plain'])
      Otto.new(routes, lambda_handlers: handlers, csrf_protection: true).tap do |app|
        app.security_config.csrf_secret = 'e' * 64
      end
    end

    def get(path)
      otto.call(Rack::MockRequest.env_for("https://example.org#{path}"))
    end

    it 'marks an HTML page private' do
      _, headers, = get('/page')

      expect(headers['cache-control']).to eq('private')
    end

    it "keeps a handler's no_cache! headers" do
      _, headers, = get('/no-cache')

      expect(headers['cache-control']).to eq('no-store, no-cache, must-revalidate, max-age=0')
    end

    it 'leaves a response without a binding or token alone' do
      _, headers, = get('/plain')

      expect(headers['cache-control']).to be_nil
    end
  end
end
