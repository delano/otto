# spec/otto/security/csrf_rack_session_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'rack/session'

# The CSRF binding behind real rack-session stores. Otto reads the binding
# from the session first, so how a store loads a session, mints its id and
# decides to commit it and set its cookie decides what the binding is and
# which cookies a response carries. The doubles in
# csrf_session_binding_spec.rb model that behavior; these examples run the
# stores themselves.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'CSRF binding behind rack-session' do
  include OttoTestHelpers

  let(:handlers) do
    {
      'form' => lambda do |_req, res, _extra|
        res['content-type'] = 'text/html'
        res.write('<html><head></head><body><form method="post"></form></body></html>')
      end,
      # Writes to the session before Otto reads it, as an app that keeps
      # state for every visitor does.
      'touch' => lambda do |req, res, _extra|
        req.session['visited'] = true
        res['content-type'] = 'text/html'
        res.write('<html><head></head><body></body></html>')
      end,
      'submit' => lambda do |_req, res, _extra|
        res['content-type'] = 'text/plain'
        res.write('accepted')
      end,
      # A token endpoint for a JSON client: no HTML, so no injected token.
      'csrf_json' => lambda do |req, res, _extra|
        config = req.env['otto.security_config']
        res['content-type'] = 'application/json'
        res.write(JSON.generate(token: config.generate_csrf_token(config.get_or_create_session_id(req))))
      end,
      # A csrf=exempt route that answers a POST with HTML, such as a callback
      # another site posts to.
      'hook' => lambda do |_req, res, _extra|
        res['content-type'] = 'text/html'
        res.write('<html><head></head><body><form method="post"></form></body></html>')
      end,
    }
  end

  let(:routes) do
    create_test_routes_file('test_routes_csrf_rack_session.txt', [
                              'GET /form &form',
                              'GET /touch &touch',
                              'POST /submit &submit',
                              'GET /csrf &csrf_json',
                              'POST /hook &hook csrf=exempt',
                            ])
  end

  let(:otto) do
    Otto.new(routes, lambda_handlers: handlers, csrf_protection: true).tap do |app|
      app.security_config.csrf_secret = 'd' * 64
    end
  end

  def config = otto.security_config

  # Sends one request through the store and Otto. Returns the status, the
  # body and the Set-Cookie lines, and merges the cookies the response sets
  # into +jar+ unless +jar+ is frozen.
  def call(method, url, jar, params = {})
    env = Rack::MockRequest.env_for(url, method: method, params: params)
    env['HTTP_COOKIE'] = jar.map { |name, value| "#{name}=#{value}" }.join('; ') unless jar.empty?
    status, headers, body = app.call(env)
    text = +''
    body.each { |chunk| text << chunk }
    set_cookies = Array(headers['set-cookie']).flat_map { |line| line.split("\n") }
    jar.merge!(set_cookies.to_h { |cookie| cookie.split(';').first.split('=', 2) }) unless jar.frozen?
    [status, text, set_cookies]
  end

  def token_in(html) = html[/name="csrf-token" content="([^"]+)"/, 1]

  def cookie_names(set_cookies) = set_cookies.map { |cookie| cookie.split('=', 2).first }

  {
    'Rack::Session::Pool' => ->(inner, **options) { Rack::Session::Pool.new(inner, **options) },
    # Rack::Session::Cookie raises on a secret shorter than 64 bytes.
    'Rack::Session::Cookie' => lambda do |inner, **options|
      Rack::Session::Cookie.new(inner, secrets: ['s' * 64], **options)
    end,
  }.each do |store_name, build_store|
    context "with #{store_name}" do
      let(:app) { build_store.call(otto) }

      it 'accepts the POST that carries the token from a new visitor\'s form' do
        jar = {}
        _, html, set_cookies = call('GET', 'https://example.org/form', jar)
        expect(cookie_names(set_cookies)).to include('rack.session')

        status, body, = call('POST', 'https://example.org/submit', jar, '_csrf_token' => token_in(html))

        expect([status, body]).to eq([200, 'accepted'])
      end

      # The store's cookie carries the binding. A copy in Otto's binding
      # cookie would outlive the session cookie with a lifetime and
      # attributes the application does not configure.
      it "does not copy the session id into Otto's binding cookie" do
        jar = {}
        _, _, first = call('GET', 'https://example.org/form', jar)
        call('GET', 'https://example.org/touch', jar)
        _, _, returning = call('GET', 'https://example.org/form', jar.except('__Host-otto_session'))

        expect(cookie_names(first + returning)).not_to include('__Host-otto_session')
      end

      # An attacker who can set cookies for the victim's browser plants a
      # copy of their own session cookie. A copy of that session's id in
      # __Host-otto_session would stay the binding after the session cookie
      # is gone, and the attacker holds tokens for it.
      it "does not carry a planted session's id past the session cookie" do
        attacker = {}
        _, attacker_html, = call('GET', 'https://example.org/touch', attacker)
        victim = { 'rack.session' => attacker['rack.session'] }
        call('GET', 'https://example.org/form', victim)
        victim.delete('rack.session')

        status, = call('POST', 'https://example.org/submit', victim, '_csrf_token' => token_in(attacker_html))

        expect(status).to eq(403)
      end

      # With secure: true, rack-session sets its cookie only when Rack sees
      # the request as HTTPS, so over HTTP no session survives between
      # requests. The binding cookie no longer stands in for it.
      context 'when the store sets secure: true and Rack sees HTTP' do
        let(:app) { build_store.call(otto, secure: true) }

        it 'rejects the token, because the session does not come back' do
          jar = {}
          _, html, set_cookies = call('GET', 'http://example.org/form', jar)
          expect(set_cookies).to be_empty

          status, = call('POST', 'http://example.org/submit', jar, '_csrf_token' => token_in(html))

          expect(status).to eq(403)
        end
      end

      it 'accepts the token from a page that wrote to the session' do
        jar = {}
        call('GET', 'https://example.org/touch', jar)
        _, html, = call('GET', 'https://example.org/touch', jar)

        status, = call('POST', 'https://example.org/submit', jar, '_csrf_token' => token_in(html))

        expect(status).to eq(200)
      end

      it 'binds the token of a returning visitor to the session id' do
        jar = {}
        call('GET', 'https://example.org/touch', jar)
        _, html, = call('GET', 'https://example.org/form', jar)

        status, = call('POST', 'https://example.org/submit', jar, '_csrf_token' => token_in(html))

        expect(status).to eq(200)
      end

      # A failed check has no binding to verify against, so it must not
      # create one: a binding minted here is written to the session, which
      # the store then commits with a new session cookie.
      it 'rejects a POST with a junk token and no cookies without setting a cookie' do
        status, _, set_cookies = call('POST', 'https://example.org/submit', {}, '_csrf_token' => 'junk')

        expect(status).to eq(403)
        expect(set_cookies).to be_empty
      end

      # A cross-site POST arrives without the victim's SameSite=Lax cookies,
      # but the browser keeps cookies set on the response to it, so they are
      # merged into the victim's jar before the victim's own POST.
      it 'sets no cookie and issues no token on a cross-site POST to an exempt HTML route' do
        victim = {}
        _, html, = call('GET', 'https://example.org/form', victim)

        cross_site = {}
        status, page, set_cookies = call('POST', 'https://example.org/hook', cross_site)
        victim.merge!(cross_site)

        expect(status).to eq(200)
        expect(set_cookies).to be_empty
        expect(token_in(page)).to be_nil
        expect(call('POST', 'https://example.org/submit', victim, '_csrf_token' => token_in(html)).first).to eq(200)
      end

      it 'issues a token that validates on a same-site POST to an exempt HTML route' do
        jar = {}
        call('GET', 'https://example.org/form', jar)
        _, page, = call('POST', 'https://example.org/hook', jar)

        status, = call('POST', 'https://example.org/submit', jar, '_csrf_token' => token_in(page))

        expect(status).to eq(200)
      end

      it 'rejects a POST without a token' do
        jar = {}
        call('GET', 'https://example.org/form', jar)

        status, = call('POST', 'https://example.org/submit', jar)

        expect(status).to eq(403)
      end
    end
  end

  # Otto runs the middleware registered first innermost, so a store added
  # with otto.use before CSRF protection is enabled runs inside
  # CSRFMiddleware. It has committed the session by the time CSRFMiddleware
  # injects the token, so the id it creates for Otto's write is neither
  # stored nor sent in its cookie.
  {
    'Rack::Session::Pool' => [Rack::Session::Pool, {}],
    'Rack::Session::Cookie' => [Rack::Session::Cookie, { secrets: ['s' * 64] }],
  }.each do |store_name, (store, options)|
    context "with #{store_name} added through otto.use before enable_csrf_protection!" do
      let(:otto) do
        Otto.new(routes, lambda_handlers: handlers).tap do |app|
          app.use(store, **options)
          app.enable_csrf_protection!
          app.security_config.csrf_secret = 'd' * 64
        end
      end
      let(:app) { otto }

      it 'runs the store inside CSRFMiddleware' do
        order = otto.middleware.execution_order

        expect(order.index(store)).to be > order.index(Otto::Security::Middleware::CSRFMiddleware)
      end

      # The binding cookie carries the id the store created for Otto's write.
      it "accepts the POST that carries the token from a new visitor's form" do
        jar = {}
        _, html, set_cookies = call('GET', 'https://example.org/form', jar)
        expect(cookie_names(set_cookies)).to eq(['__Host-otto_session'])

        status, = call('POST', 'https://example.org/submit', jar, '_csrf_token' => token_in(html))

        expect(status).to eq(200)
      end

      # The handler mints the binding before the store commits, so the
      # store's cookie carries it.
      it "accepts a new JSON client's token without a copy in the binding cookie" do
        jar = {}
        _, json, set_cookies = call('GET', 'https://example.org/csrf', jar)
        expect(cookie_names(set_cookies)).to eq(['rack.session'])

        status, = call('POST', 'https://example.org/submit', jar, '_csrf_token' => JSON.parse(json)['token'])

        expect(status).to eq(200)
      end

      it "does not carry a planted session's id past the session cookie" do
        attacker = {}
        _, attacker_html, = call('GET', 'https://example.org/touch', attacker)
        victim = { 'rack.session' => attacker['rack.session'] }
        _, _, set_cookies = call('GET', 'https://example.org/form', victim)
        victim.delete('rack.session')

        status, = call('POST', 'https://example.org/submit', victim, '_csrf_token' => token_in(attacker_html))

        expect(cookie_names(set_cookies)).not_to include('__Host-otto_session')
        expect(status).to eq(403)
      end
    end
  end
end
