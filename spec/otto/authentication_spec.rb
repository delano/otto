# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Security::AuthenticationMiddleware do
  include OttoTestHelpers

  let(:test_app) do
    lambda do |_env|
      [200, { 'Content-Type' => 'text/plain' }, ['success']]
    end
  end

  describe 'authentication strategies' do
    describe Otto::Security::PublicStrategy do
      let(:strategy) { Otto::Security::PublicStrategy.new }

      it 'allows all requests' do
        env = mock_rack_env
        result = strategy.authenticate(env, 'publically')

        expect(result).to be_success
        expect(result.user_context).to eq({})
      end
    end

    describe Otto::Security::SessionStrategy do
      let(:strategy) { Otto::Security::SessionStrategy.new }

      it 'authenticates users with valid session' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        result = strategy.authenticate(env, 'authenticated')

        expect(result).to be_success
        expect(result.user_context).to eq(user_id: 123, session: { 'user_id' => 123 })
      end

      it 'rejects requests without session' do
        env = mock_rack_env

        result = strategy.authenticate(env, 'authenticated')

        expect(result).to be_failure
        expect(result.failure_reason).to eq('No session available')
      end

      it 'rejects requests without user_id in session' do
        env = mock_rack_env
        env['rack.session'] = {}

        result = strategy.authenticate(env, 'authenticated')

        expect(result).to be_failure
        expect(result.failure_reason).to eq('Not authenticated')
      end

      it 'provides user context for authenticated requests' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 456 }

        context = strategy.user_context(env)

        expect(context).to eq(user_id: 456)
      end
    end

    describe Otto::Security::RoleStrategy do
      let(:strategy) { Otto::Security::RoleStrategy.new(%w[admin editor]) }

      it 'authenticates users with required role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_roles' => %w[admin user] }

        result = strategy.authenticate(env, 'role:admin')

        expect(result).to be_success
        expect(result.user_context).to eq(
          user_roles: %w[admin user],
          required_role: 'admin'
        )
      end

      it 'rejects users without required role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_roles' => ['user'] }

        result = strategy.authenticate(env, 'role:admin')

        expect(result).to be_failure
        expect(result.failure_reason).to eq('Insufficient privileges - requires role: admin')
      end

      it 'handles missing user_roles in session' do
        env = mock_rack_env
        env['rack.session'] = {}

        result = strategy.authenticate(env, 'role:admin')

        expect(result).to be_failure
      end
    end

    describe Otto::Security::APIKeyStrategy do
      let(:strategy) { Otto::Security::APIKeyStrategy.new(api_keys: %w[secret123 key456]) }

      it 'authenticates with valid API key in header' do
        env = mock_rack_env(headers: { 'X-API-Key' => 'secret123' })

        result = strategy.authenticate(env, 'api_key')

        expect(result).to be_success
        expect(result.user_context).to eq(api_key: 'secret123')
      end

      it 'authenticates with valid API key in parameter' do
        env = mock_rack_env(params: { 'api_key' => 'key456' })

        result = strategy.authenticate(env, 'api_key')

        expect(result).to be_success
        expect(result.user_context).to eq(api_key: 'key456')
      end

      it 'rejects invalid API key' do
        env = mock_rack_env(headers: { 'X-API-Key' => 'invalid' })

        result = strategy.authenticate(env, 'api_key')

        expect(result).to be_failure
        expect(result.failure_reason).to eq('Invalid API key')
      end

      it 'rejects requests without API key' do
        env = mock_rack_env

        result = strategy.authenticate(env, 'api_key')

        expect(result).to be_failure
        expect(result.failure_reason).to eq('No API key provided')
      end
    end

    describe Otto::Security::PermissionStrategy do
      let(:strategy) { Otto::Security::PermissionStrategy.new(%w[read write admin]) }

      it 'authenticates users with required permission' do
        env = mock_rack_env
        env['rack.session'] = { 'user_permissions' => %w[read write] }

        result = strategy.authenticate(env, 'permission:write')

        expect(result).to be_success
        expect(result.user_context).to eq(
          user_permissions: %w[read write],
          required_permission: 'write'
        )
      end

      it 'rejects users without required permission' do
        env = mock_rack_env
        env['rack.session'] = { 'user_permissions' => ['read'] }

        result = strategy.authenticate(env, 'permission:write')

        expect(result).to be_failure
        expect(result.failure_reason).to eq('Insufficient privileges - requires permission: write')
      end
    end
  end

  describe 'middleware integration' do
    let(:route_definition) do
      Otto::RouteDefinition.new('GET', '/admin', 'TestApp.admin auth=authenticated')
    end

    let(:middleware) do
      config = {
        auth_strategies: {
          'authenticated' => Otto::Security::SessionStrategy.new,
          'publically' => Otto::Security::PublicStrategy.new,
        },
      }
      Otto::Security::AuthenticationMiddleware.new(test_app, config)
    end

    it 'allows access to public routes without auth requirement' do
      env = mock_rack_env
      # No route_definition in env - should pass through

      status, _, body = middleware.call(env)

      expect(status).to eq(200)
      expect(body).to eq(['success'])
    end

    it 'allows access to routes without auth requirement' do
      env = mock_rack_env
      public_route = Otto::RouteDefinition.new('GET', '/', 'TestApp.index')
      env['otto.route_definition'] = public_route

      status, _, body = middleware.call(env)

      expect(status).to eq(200)
      expect(body).to eq(['success'])
    end

    it 'enforces authentication for protected routes' do
      env = mock_rack_env
      env['otto.route_definition'] = route_definition

      status, headers, body = middleware.call(env)

      expect(status).to eq(401)
      expect(headers['Content-Type']).to eq('application/json')

      response_data = JSON.parse(body.first)
      expect(response_data['error']).to eq('Authentication Required')
      expect(response_data['message']).to include('No session available')
    end

    it 'allows access for authenticated users' do
      env = mock_rack_env
      env['rack.session'] = { 'user_id' => 123 }
      env['otto.route_definition'] = route_definition

      status, _, body = middleware.call(env)

      expect(status).to eq(200)
      expect(body).to eq(['success'])
      expect(env['otto.user_context']).to eq(user_id: 123, session: { 'user_id' => 123 })
    end

    it 'returns error for unknown authentication strategy' do
      env = mock_rack_env
      unknown_route = Otto::RouteDefinition.new('GET', '/unknown', 'TestApp.test auth=unknown_strategy')
      env['otto.route_definition'] = unknown_route

      status, _, body = middleware.call(env)

      expect(status).to eq(401)
      response_data = JSON.parse(body.first)
      expect(response_data['message']).to include('Unknown authentication strategy: unknown_strategy')
    end
  end

  describe 'strategy pattern matching' do
    let(:middleware) do
      config = {
        auth_strategies: {
          'role' => Otto::Security::RoleStrategy.new(['admin']),
          'permission' => Otto::Security::PermissionStrategy.new(['write']),
          'custom_admin' => Otto::Security::RoleStrategy.new(['superuser']),
        },
      }
      Otto::Security::AuthenticationMiddleware.new(test_app, config)
    end

    it 'matches role: prefix requirements' do
      env = mock_rack_env
      env['rack.session'] = { 'user_roles' => ['admin'] }
      role_route = Otto::RouteDefinition.new('GET', '/admin', 'TestApp.admin auth=role:admin')
      env['otto.route_definition'] = role_route

      status, _headers, _body = middleware.call(env)

      expect(status).to eq(200)
    end

    it 'matches permission: prefix requirements' do
      env = mock_rack_env
      env['rack.session'] = { 'user_permissions' => ['write'] }
      perm_route = Otto::RouteDefinition.new('GET', '/edit', 'TestApp.edit auth=permission:write')
      env['otto.route_definition'] = perm_route

      status, _headers, _body = middleware.call(env)

      expect(status).to eq(200)
    end

    it 'matches exact strategy names over prefix matching' do
      env = mock_rack_env
      env['rack.session'] = { 'user_roles' => ['superuser'] }
      custom_route = Otto::RouteDefinition.new('GET', '/custom', 'TestApp.custom auth=custom_admin')
      env['otto.route_definition'] = custom_route

      status, _headers, _body = middleware.call(env)

      expect(status).to eq(200)
    end
  end
end

RSpec.describe Otto, 'authentication configuration' do
  include OttoTestHelpers

  describe '#configure_auth_strategies' do
    let(:otto) { create_minimal_otto }

    it 'configures authentication strategies' do
      strategies = {
        'authenticated' => Otto::Security::SessionStrategy.new,
        'publically' => Otto::Security::PublicStrategy.new,
      }

      otto.configure_auth_strategies(strategies)

      expect(otto.auth_config[:auth_strategies]).to eq(strategies)
      expect(otto.auth_config[:default_auth_strategy]).to eq('publically')
    end

    it 'enables authentication middleware when strategies configured' do
      strategies = { 'test' => Otto::Security::PublicStrategy.new }

      expect(otto.middleware_stack).to be_empty
      otto.configure_auth_strategies(strategies)
      expect(otto.middleware_stack).to include(Otto::Security::AuthenticationMiddleware)
    end
  end

  describe '#add_auth_strategy' do
    let(:otto) { create_minimal_otto }

    it 'adds a single authentication strategy' do
      strategy = Otto::Security::APIKeyStrategy.new

      otto.add_auth_strategy('api_key', strategy)

      expect(otto.auth_config[:auth_strategies]['api_key']).to eq(strategy)
    end

    it 'enables authentication middleware when strategy added' do
      expect(otto.middleware_stack).to be_empty

      otto.add_auth_strategy('test', Otto::Security::PublicStrategy.new)

      expect(otto.middleware_stack).to include(Otto::Security::AuthenticationMiddleware)
    end
  end

  describe 'initialization with auth_strategies' do
    it 'configures authentication from initialization options' do
      strategies = {
        'authenticated' => Otto::Security::SessionStrategy.new,
        'api_key' => Otto::Security::APIKeyStrategy.new,
      }

      routes_file = create_test_routes_file('auth_routes.txt', ['GET / TestApp.index'])
      otto = Otto.new(routes_file, auth_strategies: strategies)

      expect(otto.auth_config[:auth_strategies]).to eq(strategies)
      expect(otto.middleware_stack).to include(Otto::Security::AuthenticationMiddleware)
    end

    it 'does not enable authentication middleware without strategies' do
      routes_file = create_test_routes_file('no_auth_routes.txt', ['GET / TestApp.index'])
      otto = Otto.new(routes_file)

      expect(otto.middleware_stack).not_to include(Otto::Security::AuthenticationMiddleware)
    end
  end
end
