# spec/otto/security/authentication/route_auth_wrapper_session_preservation_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# RouteAuthWrapper must hand the handler the session object that the session
# middleware put in env['rack.session']. Strategies that do not return that
# object (noauth, role, permission, apikey) carry the empty Hash default from
# StrategyResult.anonymous / AuthStrategy#success, and that default must not
# replace the middleware's session: rack-session commits by calling #options
# on the object it installed, and a plain Hash has no #options.
RSpec.describe Otto::Security::Authentication::RouteAuthWrapper do
  # Stands in for Rack::Session::Abstract::SessionHash (rack-session is not a
  # dependency): a session object that is not a Hash, exposes #id and
  # #options, and supports the read/write calls the strategies make.
  let(:session_hash_class) do
    Class.new do
      attr_reader :id, :options

      def initialize(data = {})
        @data = data.transform_keys(&:to_s)
        @id = 'sid-0123456789'
        @options = { id: @id }
      end

      def [](key) = @data[key.to_s]

      def []=(key, value)
        @data[key.to_s] = value
      end

      def key?(key) = @data.key?(key.to_s)
      def dig(key, *rest) = @data.dig(key.to_s, *rest)
      def empty? = @data.empty?
      def to_hash = @data.dup
    end
  end

  let(:seen) { {} }

  let(:handler) do
    captured = seen
    lambda do |env, _extra_params|
      captured[:session] = env['rack.session']
      [200, { 'content-type' => 'text/plain' }, ['ok']]
    end
  end

  let(:api_key) { 'session-preservation-key' }

  let(:auth_config) do
    {
      auth_strategies: {
        'noauth' => Otto::Security::Authentication::Strategies::NoAuthStrategy.new,
        'session' => Otto::Security::Authentication::Strategies::SessionStrategy.new,
        'role' => Otto::Security::Authentication::Strategies::RoleStrategy.new(%w[admin]),
        'permission' => Otto::Security::Authentication::Strategies::PermissionStrategy.new(%w[write]),
        'apikey' => Otto::Security::Authentication::Strategies::APIKeyStrategy.new(api_keys: [api_key]),
      },
           login_path: '/signin',
    }
  end

  def call_route(definition, session:, headers: {})
    route = Otto::RouteDefinition.new('GET', '/resource', "TestApp.index #{definition}")
    env = Rack::MockRequest.env_for('/resource')
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    env['rack.session'] = session unless session.nil?
    status, = described_class.new(handler, route, auth_config).call(env)
    [status, env]
  end

  describe 'with a session object already in env' do
    it 'uses a session double that is not a Hash' do
      expect(session_hash_class.new).not_to be_a(Hash)
    end

    it 'passes the same session object to the handler on auth=noauth' do
      session = session_hash_class.new

      status, env = call_route('auth=noauth', session: session)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(session)
      expect(env['rack.session']).to equal(session)
    end

    it 'passes the same session object to the handler on an auth=session,noauth fall-through' do
      session = session_hash_class.new

      status, env = call_route('auth=session,noauth', session: session)

      expect(status).to eq(200)
      expect(env['otto.strategy_result'].strategy_name).to eq('noauth')
      expect(seen[:session]).to equal(session)
      expect(env['rack.session']).to equal(session)
    end

    it 'passes the same session object to the handler on a role strategy route' do
      session = session_hash_class.new('user_roles' => %w[admin])

      status, env = call_route('auth=role:admin', session: session)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(session)
      expect(env['rack.session']).to equal(session)
    end

    it 'passes the same session object to the handler on a route with role=' do
      session = session_hash_class.new('user_roles' => %w[admin])

      status, env = call_route('auth=role:admin role=admin', session: session)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(session)
      expect(env['rack.session']).to equal(session)
    end

    it 'passes the same session object to the handler on a permission strategy route' do
      session = session_hash_class.new('user_permissions' => %w[write])

      status, env = call_route('auth=permission:write', session: session)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(session)
      expect(env['rack.session']).to equal(session)
    end

    it 'passes the same session object to the handler on an auth=apikey route' do
      session = session_hash_class.new

      status, env = call_route('auth=apikey', session: session, headers: { 'X-API-Key' => api_key })

      expect(status).to eq(200)
      expect(seen[:session]).to equal(session)
      expect(env['rack.session']).to equal(session)
    end

    it 'passes the same session object to the handler on a successful session strategy' do
      session = session_hash_class.new('user_id' => 42)

      status, env = call_route('auth=session', session: session)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(session)
      expect(env['rack.session']).to equal(session)
      expect(env['otto.strategy_result'].session).to equal(session)
    end

    it 'keeps the session in env when a strategy returns a different session object' do
      session = session_hash_class.new
      other = session_hash_class.new('user_id' => 7)
      auth_config[:auth_strategies]['custom'] = strategy_returning(other)

      status, env = call_route('auth=custom', session: session)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(session)
      expect(env['otto.strategy_result'].session).to equal(other)
    end
  end

  describe 'through Otto#call behind a session middleware' do
    include OttoTestHelpers

    # Installs a session and commits it after the app returns by calling
    # #options on whatever env['rack.session'] then holds, as rack-session's
    # commit_session does.
    def call_behind_session_middleware(otto, path, session)
      env = Rack::MockRequest.env_for(path)
      env['rack.session'] = session
      status, = otto.call(env)
      env['rack.session'].options
      [status, env]
    end

    it 'commits the installed session on an auth=noauth route' do
      otto = create_minimal_otto(['GET /noauth TestApp.index auth=noauth'])
      otto.add_auth_strategy('noauth', Otto::Security::Authentication::Strategies::NoAuthStrategy.new)
      session = session_hash_class.new

      status, env = call_behind_session_middleware(otto, '/noauth', session)

      expect(status).to eq(200)
      expect(env['rack.session']).to equal(session)
    end
  end

  describe 'without a session in env' do
    it 'sets env[rack.session] to the session a strategy hands back' do
      produced = session_hash_class.new('user_id' => 7)
      auth_config[:auth_strategies]['custom'] = strategy_returning(produced)

      status, env = call_route('auth=custom', session: nil)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(produced)
      expect(env['rack.session']).to equal(produced)
    end

    it 'sets env[rack.session] to a non-empty Hash session a strategy hands back' do
      produced = { 'user_id' => 7 }
      auth_config[:auth_strategies]['custom'] = strategy_returning(produced)

      status, env = call_route('auth=custom', session: nil)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(produced)
      expect(env['rack.session']).to equal(produced)
    end

    it 'puts the auth=noauth result session into env' do
      status, env = call_route('auth=noauth', session: nil)

      expect(status).to eq(200)
      expect(seen[:session]).to eq({})
      expect(env['rack.session']).to equal(env['otto.strategy_result'].session)
    end

    it 'puts the AuthStrategy#success default session into env' do
      status, env = call_route('auth=apikey', session: nil, headers: { 'X-API-Key' => api_key })

      expect(status).to eq(200)
      expect(env['rack.session']).to equal(env['otto.strategy_result'].session)
    end

    it 'lets a handler on an auth=noauth route write env[rack.session] directly' do
      writer = lambda do |env, _extra_params|
        env['rack.session']['flash'] = 'hi'
        [200, { 'content-type' => 'text/plain' }, ['ok']]
      end
      route = Otto::RouteDefinition.new('GET', '/resource', 'TestApp.index auth=noauth')
      env = Rack::MockRequest.env_for('/resource')

      status, = described_class.new(writer, route, auth_config).call(env)

      expect(status).to eq(200)
      expect(env['rack.session']).to eq('flash' => 'hi')
    end

    it 'puts data a strategy writes into the default session after #success into env' do
      auth_config[:auth_strategies]['custom'] = Class.new(Otto::Security::Authentication::AuthStrategy) do
        def authenticate(_env, _requirement)
          result = success(user: { id: 7 })
          result.session['token_scope'] = 'read'
          result
        end
      end.new

      status, = call_route('auth=custom', session: nil)

      expect(status).to eq(200)
      expect(seen[:session]).to eq('token_scope' => 'read')
    end

    it 'puts a session derived from a default session into env' do
      auth_config[:auth_strategies]['custom'] = Class.new(Otto::Security::Authentication::AuthStrategy) do
        def authenticate(_env, _requirement)
          base = Otto::Security::Authentication::StrategyResult.anonymous
          success(user: { id: 8 }, session: base.session.merge('token_scope' => 'write'))
        end
      end.new

      status, = call_route('auth=custom', session: nil)

      expect(status).to eq(200)
      expect(seen[:session]).to eq('token_scope' => 'write')
    end

    it 'sets env[rack.session] to an empty Hash a strategy hands back' do
      produced = {}
      auth_config[:auth_strategies]['custom'] = strategy_returning(produced)

      status, env = call_route('auth=custom', session: nil)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(produced)
      expect(env['rack.session']).to equal(produced)
    end

    it 'does not put a false session into env' do
      auth_config[:auth_strategies]['custom'] = strategy_returning(false)

      status, env = call_route('auth=custom', session: nil)

      expect(status).to eq(200)
      expect(env).not_to have_key('rack.session')
    end

    it 'copies a lazy session a strategy hands back without loading it' do
      loads = []
      lazy = session_hash_class.new
      %i[[] []= key? dig empty? to_hash].each do |name|
        lazy.define_singleton_method(name) do |*|
          loads << name
          raise 'session loaded'
        end
      end
      auth_config[:auth_strategies]['custom'] = strategy_returning(lazy)

      status, env = call_route('auth=custom', session: nil)

      expect(status).to eq(200)
      expect(env['rack.session']).to equal(lazy)
      expect(loads).to be_empty
    end

    # A strategy that keeps its own server-side sessions, with no session
    # middleware: the store hands back the same Hash for a token on every
    # request, and a new token starts with an empty one. Handler writes made
    # through req.session must land in that Hash from the first request on.
    context 'when a strategy supplies the session from its own store' do
      let(:store) { Hash.new { |sessions, token| sessions[token] = {} } }

      let(:handler) do
        lambda do |env, _extra_params|
          session = Rack::Request.new(env).session
          session['visits'] = (session['visits'] || 0) + 1
          [200, { 'content-type' => 'text/plain' }, ['ok']]
        end
      end

      let(:token_strategy) do
        sessions = store
        Class.new(Otto::Security::Authentication::AuthStrategy) do
          define_method(:authenticate) do |env, _requirement|
            token = env['HTTP_X_TOKEN']
            return failure('No token') unless token

            success(user: { id: token }, session: sessions[token], auth_method: 'token')
          end
        end.new
      end

      before { auth_config[:auth_strategies]['token'] = token_strategy }

      it 'keeps the writes for a new token whose session starts empty' do
        3.times { call_route('auth=token', session: nil, headers: { 'X-Token' => 'new' }) }

        expect(store['new']).to eq('visits' => 3)
      end

      it 'keeps the writes for a token whose session already has data' do
        store['old'] = { 'seen' => true }

        3.times { call_route('auth=token', session: nil, headers: { 'X-Token' => 'old' }) }

        expect(store['old']).to eq('seen' => true, 'visits' => 3)
      end
    end
  end

  # Otto's CSRF check runs before RouteAuthWrapper and reads the session
  # through Otto::Request#session, which installs a DefaultSession when no
  # middleware provided one. That placeholder is not a session anyone
  # supplied, so a strategy's session still replaces it.
  describe 'with the placeholder session Otto::Request#session installs' do
    it 'replaces it with the session a strategy hands back' do
      produced = { 'user_id' => 7 }
      auth_config[:auth_strategies]['custom'] = strategy_returning(produced)

      status, env = call_route('auth=custom', session: Otto::Request::DefaultSession.new)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(produced)
      expect(env['rack.session']).to equal(produced)
    end

    it 'replaces it with the auth=noauth result session' do
      status, env = call_route('auth=noauth', session: Otto::Request::DefaultSession.new)

      expect(status).to eq(200)
      expect(env['rack.session']).to equal(env['otto.strategy_result'].session)
    end

    it 'keeps a plain Hash session that something other than Otto::Request installed' do
      installed = { 'user_id' => 1 }
      auth_config[:auth_strategies]['custom'] = strategy_returning({ 'user_id' => 7 })

      status, env = call_route('auth=custom', session: installed)

      expect(status).to eq(200)
      expect(seen[:session]).to equal(installed)
      expect(env['rack.session']).to equal(installed)
    end
  end

  # The same strategy-owned sessions as above, behind Otto's CSRF protection:
  # CSRFEnforcementWrapper checks the token before RouteAuthWrapper runs, and
  # the checks read the session. The strategy's session must still reach the
  # handler, and the tokens must stay valid from one request to the next.
  describe 'through Otto#call with CSRF protection and no session middleware' do
    include OttoTestHelpers

    let(:store) { { 'abc' => {} } }

    let(:otto) do
      holder = {}
      handlers = {
        'public_form' => lambda do |_req, res, _extra|
          res['content-type'] = 'text/html'
          res.write('<html><head></head><body></body></html>')
        end,
        'form' => lambda do |req, res, _extra|
          config = holder[:otto].security_config
          token = config.generate_csrf_token(config.get_or_create_session_id(req))
          res['content-type'] = 'text/html'
          res.write(%(<html><head></head><body><input name="_csrf_token" value="#{token}"></body></html>))
        end,
        'visit' => lambda do |req, res, _extra|
          req.session['visits'] = (req.session['visits'] || 0) + 1
          res['content-type'] = 'text/plain'
          res.write("visits=#{req.session['visits']}")
        end,
      }
      route_lines = [
        'GET /public-form &public_form',
        'GET /form &form auth=token',
        'POST /visit &visit auth=token',
      ]
      routes = create_test_routes_file('test_routes_session_csrf.txt', route_lines)
      holder[:otto] = Otto.new(routes, lambda_handlers: handlers, csrf_protection: true)
      holder[:otto].security_config.csrf_secret = 'a' * 64
      holder[:otto].add_auth_strategy('token', token_store_strategy)
      holder[:otto]
    end

    let(:token_store_strategy) do
      sessions = store
      Class.new(Otto::Security::Authentication::AuthStrategy) do
        define_method(:authenticate) do |env, _requirement|
          session = sessions[Rack::Request.new(env).cookies['tok']]
          return failure('No token') unless session

          success(user: { id: 'abc' }, session: session, auth_method: 'token')
        end
      end.new
    end

    let(:jar) { { 'tok' => 'abc' } }

    def request(method, path, params = {})
      env = Rack::MockRequest.env_for(path, method: method, params: params)
      env['HTTP_COOKIE'] = jar.map { |name, value| "#{name}=#{value}" }.join('; ')
      status, headers, body = otto.call(env)
      Array(headers['set-cookie']).flat_map { |line| line.split("\n") }.each do |cookie|
        name, value = cookie.split(';').first.split('=', 2)
        jar[name] = value
      end
      text = +''
      body.each { |chunk| text << chunk }
      [status, text]
    end

    it 'keeps the handler writes in the strategy session on CSRF-checked POSTs' do
      _, html = request('GET', '/public-form')
      token = html[/name="csrf-token" content="([^"]+)"/, 1]

      responses = Array.new(3) { request('POST', '/visit', '_csrf_token' => token) }

      expect(responses).to eq([[200, 'visits=1'], [200, 'visits=2'], [200, 'visits=3']])
      expect(store['abc']).to include('visits' => 3)
    end

    it 'issues tokens that match the binding cookie when the strategy session is installed' do
      _, html = request('GET', '/form')
      helper_token = html[/name="_csrf_token" value="([^"]+)"/, 1]
      meta_token = html[/name="csrf-token" content="([^"]+)"/, 1]

      expect(request('POST', '/visit', '_csrf_token' => helper_token)).to eq([200, 'visits=1'])
      expect(request('POST', '/visit', '_csrf_token' => meta_token)).to eq([200, 'visits=2'])
    end
  end

  def strategy_returning(session)
    Class.new(Otto::Security::Authentication::AuthStrategy) do
      define_method(:authenticate) do |_env, _requirement|
        success(user: { id: 7 }, session: session, auth_method: 'custom')
      end
    end.new
  end
end
