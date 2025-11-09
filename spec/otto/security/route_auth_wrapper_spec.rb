# spec/otto/security/route_auth_wrapper_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::Authentication::RouteAuthWrapper do
  include OttoTestHelpers

  let(:mock_handler) do
    lambda do |env, _extra_params|
      [200, { 'Content-Type' => 'text/plain' }, ['handler called']]
    end
  end

  let(:route_definition) do
    Otto::RouteDefinition.new('GET', '/protected', 'TestApp.protected auth=authenticated')
  end

  let(:session_strategy) { Otto::Security::SessionStrategy.new }
  let(:noauth_strategy) { Otto::Security::NoAuthStrategy.new }

  let(:auth_config) do
    {
      auth_strategies: {
        'authenticated' => session_strategy,
        'noauth' => noauth_strategy,
      },
      default_auth_strategy: 'noauth',
      login_path: '/signin',
    }
  end

  let(:wrapper) do
    described_class.new(mock_handler, route_definition, auth_config)
  end

  describe '#initialize' do
    it 'stores wrapped handler, route definition, and auth config' do
      expect(wrapper.wrapped_handler).to eq(mock_handler)
      expect(wrapper.route_definition).to eq(route_definition)
      expect(wrapper.auth_config).to eq(auth_config)
    end
  end

  describe '#call' do
    context 'with routes without auth requirement' do
      let(:public_route) do
        Otto::RouteDefinition.new('GET', '/public', 'TestApp.public')
      end

      let(:public_wrapper) do
        described_class.new(mock_handler, public_route, auth_config)
      end

      it 'sets anonymous StrategyResult and calls handler' do
        env = mock_rack_env

        status, _headers, body = public_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
        expect(env['otto.strategy_result']).to be_a(Otto::Security::Authentication::StrategyResult)
        expect(env['otto.strategy_result'].anonymous?).to be true
        expect(env['otto.strategy_result'].authenticated?).to be false
      end

      it 'includes IP metadata in anonymous result' do
        env = mock_rack_env
        env['REMOTE_ADDR'] = '192.168.1.100'

        public_wrapper.call(env)

        expect(env['otto.strategy_result'].metadata[:ip]).to eq('192.168.1.100')
      end

      it 'returns user and metadata via strategy_result for anonymous routes' do
        env = mock_rack_env

        public_wrapper.call(env)

        expect(env['otto.strategy_result'].user).to be_nil
        expect(env['otto.strategy_result'].metadata).to include(:ip)
      end
    end

    context 'with successful authentication' do
      it 'sets env variables and calls wrapped handler' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        status, _headers, body = wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
        expect(env['otto.strategy_result']).to be_a(Otto::Security::Authentication::StrategyResult)
        expect(env['otto.strategy_result']).to be_authenticated
      end

      it 'provides user via strategy_result' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 456 }

        wrapper.call(env)

        expect(env['otto.strategy_result'].user).to eq({ id: 456, user_id: 456 })
      end
    end

    context 'with authentication failure' do
      context 'JSON requests' do
        it 'returns 401 with JSON error for missing session' do
          env = mock_rack_env(headers: { 'Accept' => 'application/json' })
          env['rack.session'] = {}

          status, headers, body = wrapper.call(env)

          expect(status).to eq(401)
          expect(headers['content-type']).to eq('application/json')

          response_data = JSON.parse(body.first)
          expect(response_data['error']).to eq('Authentication Required')
          expect(response_data['message']).to eq('Not authenticated')
          expect(response_data['timestamp']).to be_a(Integer)
        end

        it 'returns 401 with JSON error for invalid credentials' do
          env = mock_rack_env(headers: { 'Accept' => 'application/json' })
          # No session at all

          status, headers, body = wrapper.call(env)

          expect(status).to eq(401)
          expect(headers['content-type']).to eq('application/json')

          response_data = JSON.parse(body.first)
          expect(response_data['error']).to eq('Authentication Required')
        end
      end

      context 'HTML requests' do
        it 'redirects to login path on authentication failure' do
          env = mock_rack_env
          env['rack.session'] = {}

          status, headers, body = wrapper.call(env)

          expect(status).to eq(302)
          expect(headers['location']).to eq('/signin')
          expect(body).to eq(['Redirecting to /signin'])
        end

        it 'uses default login path when not configured' do
          wrapper_no_login = described_class.new(
            mock_handler,
            route_definition,
            { auth_strategies: { 'authenticated' => session_strategy } }
          )

          env = mock_rack_env
          env['rack.session'] = {}

          status, headers, _body = wrapper_no_login.call(env)

          expect(status).to eq(302)
          expect(headers['location']).to eq('/signin')
        end
      end
    end

    context 'with missing strategy' do
      it 'returns 401 with error message for JSON requests' do
        unknown_route = Otto::RouteDefinition.new('GET', '/test', 'TestApp.test auth=unknown')
        wrapper_unknown = described_class.new(mock_handler, unknown_route, auth_config)

        env = mock_rack_env(headers: { 'Accept' => 'application/json' })

        status, headers, body = wrapper_unknown.call(env)

        expect(status).to eq(401)
        expect(headers['content-type']).to eq('application/json')
        response_data = JSON.parse(body.first)
        expect(response_data['error']).to eq('Authentication strategy not configured')
      end

      it 'returns 401 with error message for HTML requests' do
        unknown_route = Otto::RouteDefinition.new('GET', '/test', 'TestApp.test auth=unknown')
        wrapper_unknown = described_class.new(mock_handler, unknown_route, auth_config)

        env = mock_rack_env

        status, headers, body = wrapper_unknown.call(env)

        expect(status).to eq(401)
        expect(headers['content-type']).to eq('text/plain')
        expect(body).to eq(['Authentication strategy not configured'])
      end
    end

    context 'with extra_params' do
      it 'passes extra_params to wrapped handler' do
        captured_params = nil
        handler_with_params = lambda do |env, extra_params|
          captured_params = extra_params
          [200, {}, ['ok']]
        end

        wrapper_params = described_class.new(handler_with_params, route_definition, auth_config)
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        wrapper_params.call(env, { foo: 'bar' })

        expect(captured_params).to eq({ foo: 'bar' })
      end
    end
  end

  describe '#get_strategy' do
    it 'returns strategy and name for valid requirement' do
      strategy, name = wrapper.send(:get_strategy, 'authenticated')
      expect(strategy).to eq(session_strategy)
      expect(name).to eq('authenticated')
    end

    it 'returns nil tuple for unknown requirement' do
      strategy, name = wrapper.send(:get_strategy, 'unknown')
      expect(strategy).to be_nil
      expect(name).to be_nil
    end

    it 'returns nil tuple when auth_config is nil' do
      wrapper_no_config = described_class.new(mock_handler, route_definition, nil)
      strategy, name = wrapper_no_config.send(:get_strategy, 'authenticated')
      expect(strategy).to be_nil
      expect(name).to be_nil
    end

    it 'returns nil tuple when auth_strategies is missing' do
      wrapper_no_strategies = described_class.new(mock_handler, route_definition, {})
      strategy, name = wrapper_no_strategies.send(:get_strategy, 'authenticated')
      expect(strategy).to be_nil
      expect(name).to be_nil
    end
  end

  describe 'response format detection' do
    it 'detects JSON from Accept header' do
      env = mock_rack_env(headers: { 'Accept' => 'application/json' })
      env['rack.session'] = {}

      status, headers, _body = wrapper.call(env)

      expect(status).to eq(401)
      expect(headers['content-type']).to eq('application/json')
    end

    it 'detects JSON from Accept header with multiple types' do
      env = mock_rack_env(headers: { 'Accept' => 'text/html, application/json, */*' })
      env['rack.session'] = {}

      status, headers, _body = wrapper.call(env)

      expect(status).to eq(401)
      expect(headers['content-type']).to eq('application/json')
    end

    it 'defaults to HTML redirect when Accept header is missing' do
      env = mock_rack_env
      env['rack.session'] = {}

      status, headers, _body = wrapper.call(env)

      expect(status).to eq(302)
      expect(headers['location']).to eq('/signin')
    end

    it 'defaults to HTML redirect for non-JSON Accept headers' do
      env = mock_rack_env(headers: { 'Accept' => 'text/html' })
      env['rack.session'] = {}

      status, headers, _body = wrapper.call(env)

      expect(status).to eq(302)
      expect(headers['location']).to eq('/signin')
    end
  end

  describe 'session object identity' do
    it 'ensures env[rack.session] and strategy_result.session are the same object' do
      env = mock_rack_env
      initial_session = { 'user_id' => 123 }
      env['rack.session'] = initial_session

      wrapper.call(env)

      # Verify object identity (not just equality)
      expect(env['rack.session'].object_id).to eq(env['otto.strategy_result'].session.object_id)

      # Verify that modifying one affects the other
      env['rack.session']['new_key'] = 'new_value'
      expect(env['otto.strategy_result'].session['new_key']).to eq('new_value')
    end

    it 'maintains session object identity across strategy execution' do
      env = mock_rack_env
      session_obj = { 'user_id' => 456 }
      env['rack.session'] = session_obj

      wrapper.call(env)

      # The session object should be the exact same object
      expect(env['rack.session']).to be(session_obj)
      expect(env['otto.strategy_result'].session).to be(session_obj)
    end
  end

  describe 'strategy_name tracking' do
    context 'with anonymous routes' do
      let(:public_route) do
        Otto::RouteDefinition.new('GET', '/public', 'TestApp.public')
      end

      let(:public_wrapper) do
        described_class.new(mock_handler, public_route, auth_config)
      end

      it 'sets strategy_name to "anonymous" for routes without auth requirement' do
        env = mock_rack_env

        public_wrapper.call(env)

        expect(env['otto.strategy_result'].strategy_name).to eq('anonymous')
      end
    end

    context 'with successful authentication' do
      it 'sets strategy_name to the registered name (not class name)' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        wrapper.call(env)

        # Should be 'authenticated' (the registered name), not 'SessionStrategy' (the class name)
        expect(env['otto.strategy_result'].strategy_name).to eq('authenticated')
      end

      it 'provides strategy_name via strategy_result accessor' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 456 }

        wrapper.call(env)

        result = env['otto.strategy_result']
        expect(result.strategy_name).to eq('authenticated')
        expect(result).to respond_to(:strategy_name)
      end
    end

    context 'with authentication failure' do
      it 'sets strategy_name even when authentication fails' do
        env = mock_rack_env
        env['rack.session'] = {} # No user_id, will fail

        wrapper.call(env)

        # Even on failure, strategy_name should be set
        expect(env['otto.strategy_result'].strategy_name).to eq('authenticated')
      end
    end

    context 'with custom strategy name' do
      let(:custom_route) do
        Otto::RouteDefinition.new('GET', '/custom', 'TestApp.custom auth=custom_auth')
      end

      let(:custom_config) do
        {
          auth_strategies: {
            'custom_auth' => session_strategy, # Using SessionStrategy but registered as 'custom_auth'
          },
        }
      end

      let(:custom_wrapper) do
        described_class.new(mock_handler, custom_route, custom_config)
      end

      it 'uses the registered name, not the strategy class name' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 789 }

        custom_wrapper.call(env)

        # Should be 'custom_auth' (registered name), not 'SessionStrategy' (class name)
        expect(env['otto.strategy_result'].strategy_name).to eq('custom_auth')
        expect(env['otto.strategy_result'].strategy_name).not_to include('Session')
      end
    end
  end

  describe 'security headers consistency' do
    let(:security_config) do
      config = Otto::Security::Config.new
      # Security headers are enabled by default
      config
    end

    let(:wrapper_with_security) do
      described_class.new(mock_handler, route_definition, auth_config, security_config)
    end

    context 'on authentication failure (JSON)' do
      it 'includes security headers in 401 response' do
        env = mock_rack_env(headers: { 'Accept' => 'application/json' })
        env['rack.session'] = {}

        _status, headers, _body = wrapper_with_security.call(env)

        # Should include standard security headers from default_security_headers
        expect(headers['x-content-type-options']).to eq('nosniff')
        expect(headers['x-xss-protection']).to eq('1; mode=block')
        expect(headers['referrer-policy']).to eq('strict-origin-when-cross-origin')
      end
    end

    context 'on authentication failure (HTML redirect)' do
      it 'includes security headers in 302 response' do
        env = mock_rack_env
        env['rack.session'] = {}

        _status, headers, _body = wrapper_with_security.call(env)

        # Should include standard security headers from default_security_headers
        expect(headers['x-content-type-options']).to eq('nosniff')
        expect(headers['x-xss-protection']).to eq('1; mode=block')
        expect(headers['referrer-policy']).to eq('strict-origin-when-cross-origin')
      end
    end

    context 'when strategy not configured' do
      it 'includes security headers in error response' do
        unknown_route = Otto::RouteDefinition.new('GET', '/test', 'TestApp.test auth=unknown')
        wrapper_unknown = described_class.new(mock_handler, unknown_route, auth_config, security_config)

        env = mock_rack_env(headers: { 'Accept' => 'application/json' })

        _status, headers, _body = wrapper_unknown.call(env)

        # Should include standard security headers even on error
        expect(headers['x-content-type-options']).to eq('nosniff')
        expect(headers['x-xss-protection']).to eq('1; mode=block')
        expect(headers['referrer-policy']).to eq('strict-origin-when-cross-origin')
      end
    end
  end

  describe 'multi-strategy authentication' do
    let(:apikey_strategy) do
      Class.new do
        def authenticate(env, _requirement)
          api_key = env['HTTP_X_API_KEY']
          if api_key == 'valid_key'
            Otto::Security::Authentication::StrategyResult.success(
              user: { id: 999, api_key: api_key },
              session: nil,
              metadata: { auth_method: 'api_key' }
            )
          else
            Otto::Security::Authentication::AuthFailure.new(failure_reason: 'Invalid API key')
          end
        end
      end.new
    end

    let(:multi_auth_config) do
      {
        auth_strategies: {
          'session' => session_strategy,
          'apikey' => apikey_strategy,
        },
        default_auth_strategy: 'noauth',
        login_path: '/signin',
      }
    end

    context 'with multi-strategy route (auth=session,apikey)' do
      let(:multi_route) do
        Otto::RouteDefinition.new('GET', '/protected', 'TestApp.protected auth=session,apikey')
      end

      let(:multi_wrapper) do
        described_class.new(mock_handler, multi_route, multi_auth_config)
      end

      it 'succeeds with first strategy (session) and does not try second strategy' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        status, _headers, body = multi_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
        expect(env['otto.strategy_result']).to be_authenticated
        expect(env['otto.strategy_result'].strategy_name).to eq('session')
        expect(env['otto.strategy_result'].user[:id]).to eq(123)
      end

      it 'succeeds with second strategy (apikey) when first fails' do
        env = mock_rack_env(headers: { 'X-Api-Key' => 'valid_key' })
        env['rack.session'] = {} # No user_id, session auth will fail

        status, _headers, body = multi_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
        expect(env['otto.strategy_result']).to be_authenticated
        expect(env['otto.strategy_result'].strategy_name).to eq('apikey')
        expect(env['otto.strategy_result'].user[:id]).to eq(999)
      end

      it 'fails with 401 when all strategies fail (JSON)' do
        env = mock_rack_env(headers: { 'Accept' => 'application/json' })
        env['rack.session'] = {} # No user_id
        # No API key header

        status, headers, body = multi_wrapper.call(env)

        expect(status).to eq(401)
        expect(headers['content-type']).to eq('application/json')
        response_data = JSON.parse(body.first)
        expect(response_data['error']).to eq('Authentication Required')
      end

      it 'fails with 302 redirect when all strategies fail (HTML)' do
        env = mock_rack_env
        env['rack.session'] = {} # No user_id
        # No API key header

        status, headers, _body = multi_wrapper.call(env)

        expect(status).to eq(302)
        expect(headers['location']).to eq('/signin')
      end

      it 'sets comprehensive metadata when all strategies fail' do
        env = mock_rack_env
        env['rack.session'] = {}

        multi_wrapper.call(env)

        result = env['otto.strategy_result']
        expect(result).not_to be_authenticated
        expect(result.metadata[:attempted_strategies]).to contain_exactly('session', 'apikey')
        expect(result.metadata[:failure_reasons]).to be_an(Array)
        expect(result.metadata[:failure_reasons].size).to eq(2)
      end
    end

    context 'with unknown strategy in multi-strategy route' do
      let(:bad_route) do
        Otto::RouteDefinition.new('GET', '/test', 'TestApp.test auth=session,unknown,apikey')
      end

      let(:bad_wrapper) do
        described_class.new(mock_handler, bad_route, multi_auth_config)
      end

      it 'returns 401 immediately when encountering unknown strategy (strict mode)' do
        env = mock_rack_env(headers: { 'Accept' => 'application/json' })
        env['rack.session'] = { 'user_id' => 123 } # Session would succeed

        status, headers, body = bad_wrapper.call(env)

        expect(status).to eq(401)
        expect(headers['content-type']).to eq('application/json')
        response_data = JSON.parse(body.first)
        expect(response_data['error']).to include('unknown')
        expect(response_data['error']).to include('not configured')
      end

      it 'does not execute strategies after unknown strategy' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }
        env['HTTP_X_API_KEY'] = 'valid_key'

        # Both session and apikey would succeed, but unknown stops execution
        status, _headers, _body = bad_wrapper.call(env)

        expect(status).to eq(401)
        # Handler should not be called
        expect(env['otto.strategy_result']).to be_nil
      end
    end

    context 'with three strategies (auth=noauth,session,apikey)' do
      let(:noauth_route) do
        Otto::RouteDefinition.new('GET', '/test', 'TestApp.test auth=noauth,session,apikey')
      end

      let(:noauth_wrapper) do
        described_class.new(mock_handler, noauth_route, multi_auth_config)
      end

      it 'succeeds with first strategy (noauth) without trying others' do
        env = mock_rack_env
        # No session, no API key - noauth always succeeds

        status, _headers, body = noauth_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
        expect(env['otto.strategy_result'].strategy_name).to eq('noauth')
      end
    end
  end

  describe 'role-based authorization (Layer 1)' do
    let(:role_strategy) do
      Class.new do
        def authenticate(env, _requirement)
          session = env['rack.session']
          return Otto::Security::Authentication::AuthFailure.new(failure_reason: 'No session') unless session

          user_roles = session['user_roles'] || []
          Otto::Security::Authentication::StrategyResult.success(
            user: { id: 123, roles: user_roles },
            session: session,
            metadata: { auth_method: 'session' }
          )
        end
      end.new
    end

    let(:role_auth_config) do
      {
        auth_strategies: {
          'session' => role_strategy,
        },
        default_auth_strategy: 'noauth',
        login_path: '/signin',
      }
    end

    context 'with role requirement (role=admin)' do
      let(:admin_route) do
        Otto::RouteDefinition.new('GET', '/admin', 'AdminLogic auth=session role=admin')
      end

      let(:admin_wrapper) do
        described_class.new(mock_handler, admin_route, role_auth_config)
      end

      it 'succeeds when user has required role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['admin', 'user'] }

        status, _headers, body = admin_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
        expect(env['otto.strategy_result']).to be_authenticated
      end

      it 'returns 403 when user lacks required role (JSON)' do
        env = mock_rack_env(headers: { 'Accept' => 'application/json' })
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['user'] }

        status, headers, body = admin_wrapper.call(env)

        expect(status).to eq(403)
        expect(headers['content-type']).to eq('application/json')
        response_data = JSON.parse(body.first)
        expect(response_data['error']).to eq('Forbidden')
        expect(response_data['message']).to include('admin')
      end

      it 'returns 403 when user lacks required role (HTML)' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['user'] }

        status, headers, body = admin_wrapper.call(env)

        expect(status).to eq(403)
        expect(headers['content-type']).to eq('text/plain')
        expect(body.first).to include('admin')
      end

      it 'returns 403 when user has no roles' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => [] }

        status, _headers, _body = admin_wrapper.call(env)

        expect(status).to eq(403)
      end
    end

    context 'with multiple role requirements (role=admin,editor)' do
      let(:multi_role_route) do
        Otto::RouteDefinition.new('GET', '/content', 'ContentLogic auth=session role=admin,editor')
      end

      let(:multi_role_wrapper) do
        described_class.new(mock_handler, multi_role_route, role_auth_config)
      end

      it 'succeeds when user has first required role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['admin'] }

        status, _headers, body = multi_role_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
      end

      it 'succeeds when user has second required role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['editor'] }

        status, _headers, body = multi_role_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
      end

      it 'succeeds when user has both required roles' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['admin', 'editor', 'user'] }

        status, _headers, body = multi_role_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
      end

      it 'returns 403 when user has neither required role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['user', 'viewer'] }

        status, _headers, _body = multi_role_wrapper.call(env)

        expect(status).to eq(403)
      end
    end

    context 'with authentication but no role requirement' do
      let(:auth_only_route) do
        Otto::RouteDefinition.new('GET', '/dashboard', 'DashboardLogic auth=session')
      end

      let(:auth_only_wrapper) do
        described_class.new(mock_handler, auth_only_route, role_auth_config)
      end

      it 'succeeds regardless of user roles' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => [] }

        status, _headers, body = auth_only_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
      end

      it 'succeeds when user has roles' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['admin'] }

        status, _headers, body = auth_only_wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
      end
    end

    context 'role extraction from different sources' do
      let(:custom_strategy) do
        ->(source) do
          Class.new do
            define_method(:initialize) do
              @source = source
            end

            define_method(:authenticate) do |env, _requirement|
              case @source
              when :user_roles_accessor
                result = Otto::Security::Authentication::StrategyResult.success(
                  user: { id: 123 },
                  session: env['rack.session'],
                  metadata: {}
                )
                result.define_singleton_method(:user_roles) { ['admin'] }
                result
              when :user_hash_symbol
                Otto::Security::Authentication::StrategyResult.success(
                  user: { id: 123, roles: ['admin'] },
                  session: env['rack.session'],
                  metadata: {}
                )
              when :user_hash_string
                Otto::Security::Authentication::StrategyResult.success(
                  user: { id: 123, 'roles' => ['admin'] },
                  session: env['rack.session'],
                  metadata: {}
                )
              when :metadata
                Otto::Security::Authentication::StrategyResult.success(
                  user: { id: 123 },
                  session: env['rack.session'],
                  metadata: { user_roles: ['admin'] }
                )
              end
            end
          end.new
        end
      end

      let(:role_route) do
        Otto::RouteDefinition.new('GET', '/test', 'TestLogic auth=custom role=admin')
      end

      it 'extracts roles from user_roles accessor' do
        config = { auth_strategies: { 'custom' => custom_strategy.call(:user_roles_accessor) } }
        wrapper = described_class.new(mock_handler, role_route, config)

        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        status, _headers, _body = wrapper.call(env)
        expect(status).to eq(200)
      end

      it 'extracts roles from user[:roles]' do
        config = { auth_strategies: { 'custom' => custom_strategy.call(:user_hash_symbol) } }
        wrapper = described_class.new(mock_handler, role_route, config)

        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        status, _headers, _body = wrapper.call(env)
        expect(status).to eq(200)
      end

      it 'extracts roles from user["roles"]' do
        config = { auth_strategies: { 'custom' => custom_strategy.call(:user_hash_string) } }
        wrapper = described_class.new(mock_handler, role_route, config)

        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        status, _headers, _body = wrapper.call(env)
        expect(status).to eq(200)
      end

      it 'extracts roles from metadata[:user_roles]' do
        config = { auth_strategies: { 'custom' => custom_strategy.call(:metadata) } }
        wrapper = described_class.new(mock_handler, role_route, config)

        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        status, _headers, _body = wrapper.call(env)
        expect(status).to eq(200)
      end
    end
  end
end
