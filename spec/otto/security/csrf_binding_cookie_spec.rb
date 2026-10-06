# spec/otto/security/csrf_binding_cookie_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# When the session provides no CSRF binding (no session middleware, or a
# session without an id or stored binding), the binding comes from a cookie.
# A cookie that anyone able to set cookies for the browser can plant (a
# sibling subdomain, or a network attacker on plain HTTP) lets that attacker
# choose the binding, mint a matching token, and forge a login. On HTTPS the
# binding cookie is therefore __Host-otto_session, which browsers that enforce
# cookie name prefixes accept only with Secure, Path=/ and no Domain, from a
# secure origin; the plantable names are not read there.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'CSRF binding cookie' do
  include OttoTestHelpers

  let(:config) do
    Otto::Security::Config.new.tap do |c|
      c.enable_csrf_protection!
      c.csrf_secret = 'b' * 64
    end
  end

  def request_for(url, cookies = {})
    env = Rack::MockRequest.env_for(url)
    env['HTTP_COOKIE'] = cookies.map { |name, value| "#{name}=#{value}" }.join('; ') unless cookies.empty?
    Otto::Request.new(env)
  end

  describe 'Otto::Security::Config#csrf_binding_cookie_name' do
    it 'is __Host-otto_session on HTTPS' do
      expect(config.csrf_binding_cookie_name(request_for('https://example.org/'))).to eq('__Host-otto_session')
    end

    it 'is _otto_session on HTTP' do
      expect(config.csrf_binding_cookie_name(request_for('http://example.org/'))).to eq('_otto_session')
    end
  end

  describe 'Otto::Security::Config#get_or_create_session_id without a session binding' do
    it 'ignores _otto_session, session_id and _session_id cookies on HTTPS' do
      request = request_for('https://example.org/',
                            '_otto_session' => 'planted1', 'session_id' => 'planted2', '_session_id' => 'planted3')

      binding_id = config.get_or_create_session_id(request)

      expect(binding_id).not_to be_empty
      expect(binding_id).not_to start_with('planted')
    end

    it 'reads __Host-otto_session on HTTPS' do
      request = request_for('https://example.org/', '__Host-otto_session' => 'hostbound')

      expect(config.get_or_create_session_id(request)).to eq('hostbound')
    end

    it 'still reads _otto_session on HTTP' do
      request = request_for('http://example.org/', '_otto_session' => 'legacy')

      expect(config.get_or_create_session_id(request)).to eq('legacy')
    end

    it 'prefers a binding stored in the session over the cookie' do
      request = request_for('https://example.org/', '__Host-otto_session' => 'hostbound')
      request.env['rack.session'] = { config.csrf_session_key => 'stored' }

      expect(config.get_or_create_session_id(request)).to eq('stored')
    end
  end

  # CSRFMiddleware sets the binding cookie on a response that is not HTML
  # from env['otto.csrf_binding']. A session store's own id already reaches
  # the client in the store's cookie, so it is not recorded there: copying
  # it would put the session id in a second cookie whose lifetime and
  # attributes the application does not configure.
  describe "Otto::Security::Config#get_or_create_session_id and env['otto.csrf_binding']" do
    let(:session_class) { Class.new(Hash) { attr_accessor :id } }

    it 'records a binding read from the cookie' do
      request = request_for('https://example.org/', '__Host-otto_session' => 'hostbound')

      config.get_or_create_session_id(request)

      expect(request.env['otto.csrf_binding']).to eq('hostbound')
    end

    it 'records a binding minted without session middleware' do
      request = request_for('https://example.org/')

      binding_id = config.get_or_create_session_id(request)

      expect(request.env['otto.csrf_binding']).to eq(binding_id)
    end

    it 'records a binding stored in the session under csrf_session_key' do
      request = request_for('https://example.org/')
      request.env['rack.session'] = { config.csrf_session_key => 'stored' }

      config.get_or_create_session_id(request)

      expect(request.env['otto.csrf_binding']).to eq('stored')
    end

    it 'does not record the session id' do
      request = request_for('https://example.org/')
      request.env['rack.session'] = session_class.new.tap { |session| session.id = 'store-sid' }

      expect(config.get_or_create_session_id(request)).to eq('store-sid')
      expect(request.env).not_to have_key('otto.csrf_binding')
    end

    # rack-session's Pool and Cookie stores return the session's public id
    # for session['session_id'].
    it "does not record session['session_id']" do
      request = request_for('https://example.org/')
      request.env['rack.session'] = { 'session_id' => 'store-sid' }

      expect(config.get_or_create_session_id(request)).to eq('store-sid')
      expect(request.env).not_to have_key('otto.csrf_binding')
    end

    it 'does not record a session id the store mints when the binding is stored' do
      minting_session = session_class.new
      minting_session.define_singleton_method(:[]=) do |key, value|
        self.id ||= 'minted-sid'
        super(key, value)
      end
      request = request_for('https://example.org/')
      request.env['rack.session'] = minting_session

      expect(config.get_or_create_session_id(request)).to eq('minted-sid')
      expect(request.env).not_to have_key('otto.csrf_binding')
    end
  end

  describe 'through Otto#call without session middleware' do
    let(:otto) do
      handlers = {
        'form' => lambda do |_req, res, _extra|
          res['content-type'] = 'text/html'
          res.write('<html><head></head><body></body></html>')
        end,
        'login' => lambda do |_req, res, _extra|
          res['content-type'] = 'text/plain'
          res.write('logged in')
        end,
        # A token endpoint for a JSON client: no HTML, so no injected token.
        'csrf_json' => lambda do |req, res, _extra|
          config = holder[:otto].security_config
          token = config.generate_csrf_token(config.get_or_create_session_id(req))
          res['content-type'] = 'application/json'
          res.write(JSON.generate(token: token))
        end,
      }
      routes = create_test_routes_file('test_routes_csrf_binding_cookie.txt',
                                       ['GET /form &form', 'POST /login &login', 'GET /csrf &csrf_json'])
      holder[:otto] = Otto.new(routes, lambda_handlers: handlers, csrf_protection: true).tap do |app|
        app.security_config.csrf_secret = 'c' * 64
      end
    end

    let(:holder) { {} }

    def call(method, url, cookies, params = {})
      env = Rack::MockRequest.env_for(url, method: method, params: params)
      env['HTTP_COOKIE'] = cookies.map { |name, value| "#{name}=#{value}" }.join('; ') unless cookies.empty?
      yield env if block_given?
      status, headers, body = otto.call(env)
      text = +''
      body.each { |chunk| text << chunk }
      set_cookies = Array(headers['set-cookie']).flat_map { |line| line.split("\n") }
      [status, text, set_cookies]
    end

    def token_in(html) = html[/name="csrf-token" content="([^"]+)"/, 1]

    def cookie_jar(set_cookies)
      set_cookies.to_h { |cookie| cookie.split(';').first.split('=', 2) }
    end

    it 'sets __Host-otto_session with Secure, Path=/ and no Domain on HTTPS' do
      _, _, set_cookies = call('GET', 'https://example.org/form', {})

      binding_cookie = set_cookies.find { |cookie| cookie.start_with?('__Host-otto_session=') }
      expect(binding_cookie).not_to be_nil
      attributes = binding_cookie.split(';').drop(1).map(&:strip)
      expect(attributes).to include('Secure', 'Path=/', 'HttpOnly', 'SameSite=Lax')
      expect(attributes.grep(/\ADomain=/i)).to be_empty
      expect(set_cookies.grep(/\A_otto_session=/)).to be_empty
    end

    it 'sets _otto_session on HTTP as before' do
      _, _, set_cookies = call('GET', 'http://example.org/form', {})

      expect(set_cookies.grep(/\A_otto_session=/).size).to eq(1)
      expect(set_cookies.grep(/\A__Host-/)).to be_empty
    end

    it 'accepts a token issued on HTTPS with the __Host- cookie it set' do
      _, html, set_cookies = call('GET', 'https://example.org/form', {})

      status, = call('POST', 'https://example.org/login', cookie_jar(set_cookies), '_csrf_token' => token_in(html))

      expect(status).to eq(200)
    end

    it 'refuses a login forged with a planted _otto_session on HTTPS' do
      planted = { '_otto_session' => 'attackerchosen' }
      _, attacker_html, = call('GET', 'https://example.org/form', planted)

      status, = call('POST', 'https://example.org/login', planted, '_csrf_token' => token_in(attacker_html))

      expect(status).to eq(403)
    end

    # A JSON client never receives an HTML response, so the binding cookie
    # must be set on whatever response the request that created the binding
    # gets. Here the client's app-set session_id cookie is ignored on HTTPS.
    it 'sets the binding cookie on a JSON response and accepts the next POST' do
      jar = { 'session_id' => 'appsid123' }
      _, body, set_cookies = call('GET', 'https://example.org/csrf', jar)

      binding_cookie = set_cookies.find { |cookie| cookie.start_with?('__Host-otto_session=') }
      expect(binding_cookie).not_to be_nil
      expect(binding_cookie.split(';').drop(1).map(&:strip)).to include('Secure', 'Path=/')
      jar.merge!(cookie_jar(set_cookies))

      status, = call('POST', 'https://example.org/login', jar, '_csrf_token' => JSON.parse(body)['token'])

      expect(status).to eq(200)
    end

    # Rack URL-decodes cookie values, so an app-set session_id sent as
    # a%3Bb%2541 is the binding "a;b%41". Written unencoded, the browser would
    # keep _otto_session=a and the next POST would carry another binding.
    it 'encodes the binding cookie value so the next request reads the same binding' do
      jar = { 'session_id' => 'a%3Bb%2541' }
      _, body, set_cookies = call('GET', 'http://example.org/csrf', jar)

      expect(set_cookies.grep(/\A_otto_session=/)).to all(start_with('_otto_session=a%3Bb%2541;'))
      expect(set_cookies.grep(/\A_otto_session=/).size).to eq(1)
      jar.merge!(cookie_jar(set_cookies))
      token = JSON.parse(body)['token']

      statuses = Array.new(2) { call('POST', 'http://example.org/login', jar, '_csrf_token' => token).first }

      expect(statuses).to eq([200, 200])
    end

    # Behind a session middleware the store's cookie carries the binding.
    # The same session object stands in for one the store persisted.
    context 'with a session that has an id' do
      it 'does not copy the session id into a binding cookie on a JSON response' do
        session = Class.new(Hash) { attr_accessor :id }.new.tap { |s| s.id = 'store-sid' }
        _, body, set_cookies = call('GET', 'https://example.org/csrf', {}) { |env| env['rack.session'] = session }

        expect(set_cookies.grep(/\A(?:__Host-otto_session|_otto_session)=/)).to be_empty

        status, = call('POST', 'https://example.org/login', {}, '_csrf_token' => JSON.parse(body)['token']) do |env|
          env['rack.session'] = session
        end

        expect(status).to eq(200)
      end
    end

    it 'does not set the binding cookie again once the request carries it' do
      _, _, set_cookies = call('GET', 'https://example.org/csrf', {})
      jar = cookie_jar(set_cookies)

      _, _, again = call('GET', 'https://example.org/csrf', jar)

      expect(again.grep(/\A__Host-otto_session=/)).to be_empty
    end
  end
end
