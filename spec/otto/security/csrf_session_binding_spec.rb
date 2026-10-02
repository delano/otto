# spec/otto/security/csrf_session_binding_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

# Minimal stand-in for rack-session 2.x, which is not a dependency of this gem.
# It follows Rack::Session::Abstract::SessionHash and Rack::Session::Pool in the
# four ways that matter for the CSRF binding:
#
# - The session loads lazily. Without a session cookie, #id is nil and a read
#   loads nothing; the first write mints an id. With a cookie, #id is the
#   cookie's id until the first read or write loads the session, which mints a
#   new id when the pool holds no data for the cookie's id.
# - The id is a SessionId object, not a String. Its #to_s is the cookie value.
# - Setting :renew in env['rack.session.options'] moves the session data to a
#   new id when the response is committed and deletes the old id, as
#   Rack::Session::Pool#delete_session does. Apps do this at login to defeat
#   session fixation.
# - Setting :drop deletes the session data when the response is committed and
#   sets no cookie, so the next request still carries the dropped id, as
#   Rack::Session::Pool#delete_session and commit_session do.
module CsrfSessionBindingSpec
  class SessionId
    attr_reader :public_id

    alias to_s public_id

    def initialize(public_id)
      @public_id = public_id
    end

    def empty?
      false
    end
  end

  # One per request, as rack-session builds one per request.
  class LazySession
    def initialize(pool, cookie_sid)
      @pool       = pool
      @cookie_sid = cookie_sid
      @loaded     = false
    end

    def id
      return @id if @loaded || instance_variable_defined?(:@id)

      @id = (SessionId.new(@cookie_sid) if @cookie_sid)
    end

    def loaded?
      @loaded
    end

    def [](key)
      load! if !@loaded && @cookie_sid
      (@data || {})[key.to_s]
    end

    def []=(key, value)
      load! unless @loaded
      @data[key.to_s] = value
    end

    def to_hash
      @data.dup
    end

    def renew!(new_id)
      @id = new_id
    end

    private

    def load!
      if @pool.key?(@cookie_sid)
        @id   = SessionId.new(@cookie_sid)
        @data = @pool[@cookie_sid].dup
      else
        @id   = SessionId.new(SecureRandom.hex(16))
        @data = {}
      end
      @loaded = true
    end
  end

  # Installs a LazySession per request and, like rack-session's
  # commit_session, saves a loaded session and sets its cookie when the
  # request did not already carry that id.
  class SessionMiddleware
    COOKIE = 'rack.session'

    attr_reader :pool

    def initialize(app)
      @app  = app
      @pool = {}
    end

    def call(env)
      cookie_sid                  = Rack::Request.new(env).cookies[COOKIE]
      session                     = LazySession.new(@pool, cookie_sid)
      env['rack.session']         = session
      env['rack.session.options'] = {}

      status, headers, body = @app.call(env)
      commit(session, cookie_sid, env['rack.session.options'], headers)
      [status, headers, body]
    end

    private

    def commit(session, cookie_sid, options, headers)
      if options[:drop]
        @pool.delete(session.id&.public_id)
        return
      end

      return unless session.loaded?

      if options[:renew]
        @pool.delete(session.id.public_id)
        session.renew!(SessionId.new(SecureRandom.hex(16)))
      end

      sid        = session.id.public_id
      @pool[sid] = session.to_hash
      return if cookie_sid == sid

      Rack::Utils.set_cookie_header!(headers, COOKIE, { value: sid, path: '/' })
    end
  end
end

# The CSRF binding must be the same value on the request that issues a token
# and on the request that submits it, including when the session store loads
# lazily and mints its id only on the first write. Integration spec over a
# behaviour, not a class.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'CSRF session binding with a lazily loaded session' do
  include Rack::Test::Methods

  let(:otto) do
    stub_const('CsrfBindingApp', Class.new do
      def self.form(_req, res)
        res['content-type'] = 'text/html'
        res.write('<html><head></head><body><form method="post"></form></body></html>')
      end

      # Writes to the session before Otto reads it, so the session is already
      # loaded and has an id when the CSRF token is issued.
      def self.touch(req, res)
        req.session['visited'] = true
        form(req, res)
      end

      def self.submit(_req, res)
        res['content-type'] = 'text/plain'
        res.write('accepted')
      end

      # Drops the session on logout and renders the login form in the same
      # response.
      def self.logout(req, res)
        req.env['rack.session.options'][:drop] = true
        form(req, res)
      end

      # Renews the session id on login, the usual session fixation defence.
      def self.login(req, res)
        req.env['rack.session.options'][:renew] = true
        req.session['user'] = 'member'
        submit(req, res)
      end
    end)

    route_lines = [
      'GET /form CsrfBindingApp.form',
      'GET /touch CsrfBindingApp.touch',
      'GET /logout CsrfBindingApp.logout',
      'POST /submit CsrfBindingApp.submit',
      'POST /login CsrfBindingApp.login',
    ]
    routes   = create_test_routes_file('csrf_session_binding_routes.txt', route_lines)
    instance = Otto.new(routes, csrf_protection: true)
    instance.security_config.csrf_secret = SecureRandom.hex(32)
    instance
  end

  let(:session_store) { CsrfSessionBindingSpec::SessionMiddleware.new(otto) }

  def app
    session_store
  end

  def issued_token
    last_response.body[/<meta name="csrf-token" content="([^"]+)">/, 1]
  end

  def otto_session_cookies
    Array(last_response.headers['set-cookie'])
      .flat_map { |value| value.split("\n") }
      .grep(/\A_otto_session=/)
  end

  def submit(token)
    post '/submit', '_csrf_token' => token
    last_response
  end

  context 'with a new visitor whose first page does not touch the session' do
    it 'accepts the POST that carries the token from that page' do
      get '/form'
      expect(last_response.status).to eq(200)
      token = issued_token
      expect(token).not_to be_nil
      expect(session_store.pool.size).to eq(1) # the binding write minted the session

      response = submit(token)
      expect(response.status).to eq(200)
      expect(response.body).to eq('accepted')
    end

    it 'keeps the token from the first page valid after another page is loaded' do
      get '/form'
      first_token = issued_token
      get '/form'

      expect(submit(first_token).status).to eq(200)
    end

    it 'does not set the _otto_session cookie again once it matches the binding' do
      get '/form'
      expect(otto_session_cookies.size).to eq(1)

      get '/form'
      expect(otto_session_cookies).to be_empty
    end
  end

  context 'when the session already has an id before the token is issued' do
    it 'accepts a token issued after the app wrote to the session' do
      get '/touch'
      expect(submit(issued_token).status).to eq(200)
    end

    it 'accepts a token issued to a returning visitor whose session the app loaded' do
      get '/touch'
      get '/touch'

      expect(submit(issued_token).status).to eq(200)
    end

    it 'accepts a token issued to a returning visitor on a page that does not touch the session' do
      get '/touch'
      get '/form'

      expect(submit(issued_token).status).to eq(200)
    end

    it 'does not set the _otto_session cookie again when it already holds the session id' do
      get '/touch'
      expect(otto_session_cookies.size).to eq(1)

      get '/touch'
      expect(otto_session_cookies).to be_empty
    end
  end

  context 'when the app renews the session id at login' do
    # With session fixation, an attacker plants their own session cookie in
    # the victim's browser and keeps a token issued to that session. The
    # renewal at login must retire that token along with the old id.
    it 'rejects a token issued before the renewal' do
      get '/form'
      pre_login_token = issued_token

      post '/login', '_csrf_token' => pre_login_token
      expect(last_response.status).to eq(200)
      expect(session_store.pool.size).to eq(1) # the data moved to the new id

      expect(submit(pre_login_token).status).to eq(403)
    end

    it 'accepts a token issued after the renewal' do
      get '/form'
      post '/login', '_csrf_token' => issued_token
      get '/form'

      expect(submit(issued_token).status).to eq(200)
    end
  end

  context 'when the app drops the session and renders a login form' do
    # The token is bound to the dropped id, which stays in the client's cookie.
    # On the POST, session.id returns that id until the session loads; loading
    # it mints a new id because the data is gone. Reading session data before
    # session.id would load it and reject the token.
    it 'accepts the POST that carries the token from that page' do
      get '/touch'
      get '/logout'
      logout_token = issued_token
      expect(session_store.pool).to be_empty # the drop deleted the data

      post '/login', '_csrf_token' => logout_token
      expect(last_response.status).to eq(200)
    end
  end

  describe 'Otto::Security::Config#get_or_create_session_id' do
    it 'returns a String when the session id is not a String' do
      pool = { 'abc123' => { 'visited' => true } }
      env  = mock_rack_env(method: 'GET', path: '/')
      env['rack.session'] = CsrfSessionBindingSpec::LazySession.new(pool, 'abc123')

      session_id = otto.security_config.get_or_create_session_id(Rack::Request.new(env))

      expect(session_id).to eq('abc123')
      expect(session_id).to be_a(String)
    end
  end
end
