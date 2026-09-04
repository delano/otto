# Testing Guide for Otto 2 Applications

A guide to testing Otto 2 applications, covering Logic classes, authentication strategies, routes, authorization, and full-stack request specs.

Updated: 2025-11-22

## Table of Contents

1. [Testing Principles](#testing-principles)
2. [Test Environment Setup](#test-environment-setup)
3. [Testing Logic Classes](#testing-logic-classes)
4. [Testing Authentication Strategies](#testing-authentication-strategies)
5. [Testing Route Definitions](#testing-route-definitions)
6. [Testing Authorization](#testing-authorization)
7. [Request Specs (Full-Stack)](#request-specs-full-stack)
8. [Testing Error Handlers](#testing-error-handlers)
9. [Testing Middleware](#testing-middleware)
10. [Shared Examples](#shared-examples)
11. [Best Practices](#best-practices)

## Testing Principles

Otto 2 testing follows these core principles:

1. **Handler-Level Authentication**: Test authentication at the handler level (RouteAuthWrapper), not middleware
2. **Two-Layer Authorization**: Test both route-level (auth=, role=) and resource-level (raise_concerns) authorization
3. **Strategy Result Pattern**: Use `env['otto.strategy_result']` for authentication state
4. **Direct Rack Testing**: Use Rack::Test for full-stack integration tests
5. **Security by Default**: All tests should verify security headers and IP privacy
6. **Configuration Freezing**: Test configuration freeze after first request

## Test Environment Setup

### spec_helper.rb

```ruby
# spec/spec_helper.rb
require 'bundler/setup'
require 'rack'
require 'rack/test'
require 'json'
require_relative '../lib/otto'

# Configure Otto for testing
Otto.debug = ENV['OTTO_DEBUG'] == 'true'
Otto.logger.level = Logger::WARN unless Otto.debug

RSpec.configure do |config|
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.include Rack::Test::Methods
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) do
    ENV['RACK_ENV'] = 'test'
  end
end

# Load support files
Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }
```

### Test Helpers

```ruby
# spec/support/test_helpers.rb
module OttoTestHelpers
  # Create a mock Rack environment
  def mock_rack_env(method: 'GET', path: '/', headers: {})
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'QUERY_STRING' => '',
      'rack.input' => StringIO.new,
      'rack.session' => {},
      'REMOTE_ADDR' => '127.0.0.1',
    }.tap do |env|
      headers.each do |key, value|
        env["HTTP_#{key.to_s.upcase.tr('-', '_')}"] = value
      end
    end
  end

  # Create minimal Otto instance for testing
  def create_minimal_otto
    Otto.new
  end

  # Create Otto instance with security enabled
  def create_secure_otto
    Otto.new.tap do |otto|
      otto.security_config.enable_security_headers = true
    end
  end

  # Extract security headers from response
  def extract_security_headers(response)
    headers = response[1]
    headers.select { |k, _| k.start_with?('x-') || k == 'referrer-policy' }
  end
end
```

## Testing Logic Classes

Logic classes are Otto's equivalent to Rails controllers. They follow a specific lifecycle:
1. Initialize with `context`, `params`, `locale`
2. Execute `raise_concerns` (optional validation/authorization)
3. Execute `process` (main business logic)
4. Return `response_data` (for JSON responses)

### Basic Logic Class Test

```ruby
# spec/logic/dashboard_logic_spec.rb
require 'spec_helper'

RSpec.describe DashboardLogic do
  let(:strategy_result) do
    Otto::Security::Authentication::StrategyResult.new(
      user: { id: 123, name: 'Test User' },
      session: { 'user_id' => 123 },
      auth_method: 'session',
      metadata: {},
      strategy_name: 'session'
    )
  end

  let(:params) { { filter: 'recent' } }
  let(:locale) { 'en' }

  describe '#initialize' do
    it 'accepts context, params, and locale' do
      logic = described_class.new(strategy_result, params, locale)

      expect(logic.context).to eq(strategy_result)
      expect(logic.params).to eq(params)
      expect(logic.locale).to eq(locale)
    end
  end

  describe '#raise_concerns' do
    it 'raises error when user is not authenticated' do
      anonymous = Otto::Security::Authentication::StrategyResult.anonymous
      logic = described_class.new(anonymous, params, locale)

      expect { logic.raise_concerns }.to raise_error(Otto::Security::AuthorizationError)
    end

    it 'passes when user is authenticated' do
      logic = described_class.new(strategy_result, params, locale)

      expect { logic.raise_concerns }.not_to raise_error
    end
  end

  describe '#process' do
    it 'returns dashboard data for authenticated user' do
      logic = described_class.new(strategy_result, params, locale)

      result = logic.process

      expect(result).to be_a(Hash)
      expect(result[:user_id]).to eq(123)
      expect(result[:filter]).to eq('recent')
    end

    it 'applies filter from params' do
      params[:filter] = 'all'
      logic = described_class.new(strategy_result, params, locale)

      result = logic.process

      expect(result[:filter]).to eq('all')
    end
  end

  describe '#response_data' do
    it 'wraps process result in response structure' do
      logic = described_class.new(strategy_result, params, locale)

      result = logic.response_data

      expect(result).to have_key(:dashboard)
      expect(result[:dashboard][:user_id]).to eq(123)
    end
  end
end
```

### Testing Logic Class with Resource Authorization

```ruby
# spec/logic/post_edit_logic_spec.rb
require 'spec_helper'

RSpec.describe PostEditLogic do
  let(:user_id) { 123 }
  let(:strategy_result) do
    Otto::Security::Authentication::StrategyResult.new(
      user: { id: user_id },
      session: { 'user_id' => user_id },
      auth_method: 'session',
      metadata: {},
      strategy_name: 'session'
    )
  end

  let(:post) { double('Post', id: 1, user_id: user_id, title: 'Test Post') }
  let(:params) { { id: 1, title: 'Updated Title' } }

  before do
    allow(Post).to receive(:find).with(1).and_return(post)
  end

  describe '#raise_concerns' do
    context 'when user owns the post' do
      it 'allows access' do
        logic = described_class.new(strategy_result, params, 'en')

        expect { logic.raise_concerns }.not_to raise_error
      end
    end

    context 'when user does not own the post' do
      let(:other_user_post) { double('Post', id: 1, user_id: 456) }

      before do
        allow(Post).to receive(:find).with(1).and_return(other_user_post)
      end

      it 'raises AuthorizationError' do
        logic = described_class.new(strategy_result, params, 'en')

        expect { logic.raise_concerns }.to raise_error(
          Otto::Security::AuthorizationError,
          /Cannot edit another user's post/
        )
      end

      it 'includes resource context in error' do
        logic = described_class.new(strategy_result, params, 'en')

        begin
          logic.raise_concerns
        rescue Otto::Security::AuthorizationError => e
          expect(e.resource).to eq('Post')
          expect(e.action).to eq('edit')
          expect(e.user_id).to eq(123)
        end
      end
    end

    context 'when post does not exist' do
      before do
        allow(Post).to receive(:find).with(999).and_raise(ActiveRecord::RecordNotFound)
      end

      it 'raises RecordNotFound' do
        params[:id] = 999
        logic = described_class.new(strategy_result, params, 'en')

        expect { logic.raise_concerns }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe '#process' do
    it 'updates post with new title' do
      logic = described_class.new(strategy_result, params, 'en')
      logic.raise_concerns

      expect(post).to receive(:update!).with(title: 'Updated Title')
      logic.process
    end

    it 'returns updated post data' do
      allow(post).to receive(:update!)
      logic = described_class.new(strategy_result, params, 'en')
      logic.raise_concerns

      result = logic.process

      expect(result[:post_id]).to eq(1)
      expect(result[:title]).to eq('Updated Title')
    end
  end
end
```

### Testing Logic Class with JSON Body Parsing

```ruby
# spec/logic/api_create_logic_spec.rb
require 'spec_helper'

RSpec.describe ApiCreateLogic do
  let(:strategy_result) do
    Otto::Security::Authentication::StrategyResult.new(
      user: { id: 123, api_key: 'test_key' },
      session: nil,
      auth_method: 'api_key',
      metadata: {},
      strategy_name: 'apikey'
    )
  end

  describe '#process with JSON params' do
    it 'merges JSON body data with query params' do
      json_params = { name: 'Widget', price: 99.99 }
      query_params = { category: 'electronics' }
      merged_params = query_params.merge(json_params)

      logic = described_class.new(strategy_result, merged_params, 'en')
      result = logic.process

      expect(result[:name]).to eq('Widget')
      expect(result[:price]).to eq(99.99)
      expect(result[:category]).to eq('electronics')
    end
  end
end
```

## Testing Authentication Strategies

Authentication strategies are handler-level components that execute before route handlers.

### Testing Built-in SessionStrategy

```ruby
# spec/strategies/session_strategy_spec.rb
require 'spec_helper'

RSpec.describe Otto::Security::Authentication::Strategies::SessionStrategy do
  let(:strategy) { described_class.new(session_key: 'user_id') }

  describe '#authenticate' do
    context 'with valid session' do
      it 'returns StrategyResult with user data' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        result = strategy.authenticate(env, 'session')

        expect(result).to be_a(Otto::Security::Authentication::StrategyResult)
        expect(result.authenticated?).to be true
        expect(result.user[:id]).to eq(123)
        expect(result.user_id).to eq(123)
        expect(result.auth_method).to eq('session')
      end

      it 'preserves session object reference' do
        env = mock_rack_env
        session = { 'user_id' => 123 }
        env['rack.session'] = session

        result = strategy.authenticate(env, 'session')

        expect(result.session.object_id).to eq(session.object_id)
      end
    end

    context 'without valid session' do
      it 'returns AuthFailure when session is missing' do
        env = mock_rack_env
        # No rack.session set

        result = strategy.authenticate(env, 'session')

        expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
        expect(result.failure_reason).to match(/No session/)
      end

      it 'returns AuthFailure when user_id is missing' do
        env = mock_rack_env
        env['rack.session'] = {}

        result = strategy.authenticate(env, 'session')

        expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
        expect(result.failure_reason).to match(/Not authenticated/)
      end
    end
  end
end
```

### Testing Custom Authentication Strategy

```ruby
# spec/strategies/custom_token_strategy_spec.rb
require 'spec_helper'

RSpec.describe CustomTokenStrategy do
  let(:valid_token) { 'valid_token_12345' }
  let(:strategy) { described_class.new(token_validator: double('Validator')) }

  describe '#authenticate' do
    context 'with valid Authorization header' do
      it 'returns StrategyResult with user data' do
        env = mock_rack_env(headers: { 'Authorization' => "Bearer #{valid_token}" })
        allow(strategy.token_validator).to receive(:validate)
          .with(valid_token)
          .and_return({ id: 456, email: 'user@example.com' })

        result = strategy.authenticate(env, 'token')

        expect(result).to be_a(Otto::Security::Authentication::StrategyResult)
        expect(result.authenticated?).to be true
        expect(result.user[:id]).to eq(456)
        expect(result.user[:email]).to eq('user@example.com')
        expect(result.auth_method).to eq('token')
      end
    end

    context 'with invalid token' do
      it 'returns AuthFailure' do
        env = mock_rack_env(headers: { 'Authorization' => 'Bearer invalid_token' })
        allow(strategy.token_validator).to receive(:validate)
          .with('invalid_token')
          .and_return(nil)

        result = strategy.authenticate(env, 'token')

        expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
        expect(result.failure_reason).to match(/Invalid token/)
      end
    end

    context 'without Authorization header' do
      it 'returns AuthFailure' do
        env = mock_rack_env

        result = strategy.authenticate(env, 'token')

        expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
        expect(result.failure_reason).to match(/No token provided/)
      end
    end
  end

  describe '#user_context' do
    it 'returns additional user metadata' do
      env = mock_rack_env(headers: { 'Authorization' => "Bearer #{valid_token}" })
      allow(strategy.token_validator).to receive(:validate)
        .and_return({ id: 456, roles: ['editor'] })

      context = strategy.user_context(env)

      expect(context[:roles]).to eq(['editor'])
    end
  end
end
```

### Testing APIKeyStrategy

```ruby
# spec/strategies/api_key_strategy_spec.rb
require 'spec_helper'

RSpec.describe Otto::Security::Authentication::Strategies::APIKeyStrategy do
  let(:valid_keys) { ['key_123', 'key_456'] }
  let(:strategy) { described_class.new(api_keys: valid_keys) }

  describe '#authenticate' do
    context 'with valid API key in header' do
      it 'returns StrategyResult' do
        env = mock_rack_env(headers: { 'X-API-Key' => 'key_123' })

        result = strategy.authenticate(env, 'apikey')

        expect(result).to be_a(Otto::Security::Authentication::StrategyResult)
        expect(result.authenticated?).to be true
        expect(result.user[:api_key]).to eq('key_123')
      end
    end

    context 'with valid API key in query parameter' do
      it 'returns StrategyResult' do
        env = mock_rack_env(path: '/api/data?api_key=key_123')
        env['QUERY_STRING'] = 'api_key=key_123'

        result = strategy.authenticate(env, 'apikey')

        expect(result).to be_a(Otto::Security::Authentication::StrategyResult)
        expect(result.authenticated?).to be true
      end
    end

    context 'with invalid API key' do
      it 'returns AuthFailure' do
        env = mock_rack_env(headers: { 'X-API-Key' => 'invalid_key' })

        result = strategy.authenticate(env, 'apikey')

        expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
        expect(result.failure_reason).to match(/Invalid API key/)
      end
    end

    context 'without API key' do
      it 'returns AuthFailure' do
        env = mock_rack_env

        result = strategy.authenticate(env, 'apikey')

        expect(result).to be_a(Otto::Security::Authentication::AuthFailure)
        expect(result.failure_reason).to match(/No API key provided/)
      end
    end
  end
end
```

## Testing Route Definitions

Test route parsing and definition creation.

### Testing Route Parsing

```ruby
# spec/routes/route_definition_spec.rb
require 'spec_helper'

RSpec.describe Otto::RouteDefinition do
  describe 'parsing route with auth requirement' do
    it 'extracts auth requirement from definition' do
      definition = described_class.new('GET', '/protected', 'Logic auth=session')

      expect(definition.verb).to eq('GET')
      expect(definition.path).to eq('/protected')
      expect(definition.auth_requirement).to eq('session')
      expect(definition.kind).to eq(:logic_class)
    end

    it 'extracts multiple auth strategies' do
      definition = described_class.new('GET', '/api', 'Logic auth=session,apikey')

      expect(definition.auth_requirement).to eq('session,apikey')
      expect(definition.auth_strategies).to eq(['session', 'apikey'])
    end
  end

  describe 'parsing route with role requirement' do
    it 'extracts role requirement' do
      definition = described_class.new('GET', '/admin', 'Logic auth=session role=admin')

      expect(definition.auth_requirement).to eq('session')
      expect(definition.role_requirement).to eq('admin')
    end

    it 'extracts multiple roles' do
      definition = described_class.new('GET', '/content', 'Logic auth=session role=admin,editor')

      expect(definition.role_requirement).to eq('admin,editor')
      expect(definition.roles).to eq(['admin', 'editor'])
    end
  end

  describe 'parsing route with response type' do
    it 'extracts response type' do
      definition = described_class.new('GET', '/api/data', 'Logic auth=apikey response=json')

      expect(definition.response_type).to eq('json')
      expect(definition.auth_requirement).to eq('apikey')
    end
  end

  describe 'parsing handler types' do
    it 'identifies logic class handler' do
      definition = described_class.new('GET', '/logic', 'DashboardLogic')

      expect(definition.kind).to eq(:logic_class)
      expect(definition.handler_class).to eq('DashboardLogic')
    end

    it 'identifies instance method handler' do
      definition = described_class.new('GET', '/show', 'Controller#show')

      expect(definition.kind).to eq(:instance_method)
      expect(definition.handler_class).to eq('Controller')
      expect(definition.handler_method).to eq('show')
    end

    it 'identifies class method handler' do
      definition = described_class.new('GET', '/index', 'Controller.index')

      expect(definition.kind).to eq(:class_method)
      expect(definition.handler_class).to eq('Controller')
      expect(definition.handler_method).to eq('index')
    end
  end
end
```

## Testing Authorization

Otto uses two-layer authorization: route-level (RouteAuthWrapper) and resource-level (raise_concerns in Logic classes).

### Testing Route-Level Authorization (RouteAuthWrapper)

```ruby
# spec/security/route_auth_wrapper_spec.rb
require 'spec_helper'

RSpec.describe Otto::Security::Authentication::RouteAuthWrapper do
  let(:mock_handler) do
    lambda do |env, _extra_params|
      [200, { 'Content-Type' => 'text/plain' }, ['handler called']]
    end
  end

  let(:session_strategy) { Otto::Security::SessionStrategy.new }

  let(:auth_config) do
    {
      auth_strategies: { 'session' => session_strategy },
      login_path: '/signin',
    }
  end

  describe 'authentication enforcement' do
    let(:route_definition) do
      Otto::RouteDefinition.new('GET', '/protected', 'Logic auth=session')
    end

    let(:wrapper) do
      described_class.new(mock_handler, route_definition, auth_config)
    end

    context 'with authenticated user' do
      it 'allows access and calls handler' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        status, _headers, body = wrapper.call(env)

        expect(status).to eq(200)
        expect(body).to eq(['handler called'])
        expect(env['otto.strategy_result']).to be_authenticated
      end

      it 'sets strategy_result in env' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123 }

        wrapper.call(env)

        result = env['otto.strategy_result']
        expect(result).to be_a(Otto::Security::Authentication::StrategyResult)
        expect(result.user_id).to eq(123)
        expect(result.strategy_name).to eq('session')
      end
    end

    context 'without authentication' do
      it 'returns 401 for JSON requests' do
        env = mock_rack_env(headers: { 'Accept' => 'application/json' })
        env['rack.session'] = {}

        status, headers, body = wrapper.call(env)

        expect(status).to eq(401)
        expect(headers['content-type']).to eq('application/json')
        expect(JSON.parse(body.first)['error']).to eq('Authentication Required')
      end

      it 'redirects to login for HTML requests' do
        env = mock_rack_env
        env['rack.session'] = {}

        status, headers, _body = wrapper.call(env)

        expect(status).to eq(302)
        expect(headers['location']).to eq('/signin')
      end
    end
  end

  describe 'multi-strategy authentication' do
    let(:apikey_strategy) do
      Otto::Security::Authentication::Strategies::APIKeyStrategy.new(
        api_keys: ['valid_key']
      )
    end

    let(:multi_auth_config) do
      {
        auth_strategies: {
          'session' => session_strategy,
          'apikey' => apikey_strategy,
        },
      }
    end

    let(:route_definition) do
      Otto::RouteDefinition.new('GET', '/api', 'Logic auth=session,apikey')
    end

    let(:wrapper) do
      described_class.new(mock_handler, route_definition, multi_auth_config)
    end

    it 'succeeds with first strategy (session)' do
      env = mock_rack_env
      env['rack.session'] = { 'user_id' => 123 }

      status, _headers, _body = wrapper.call(env)

      expect(status).to eq(200)
      expect(env['otto.strategy_result'].strategy_name).to eq('session')
    end

    it 'succeeds with second strategy (apikey) when first fails' do
      env = mock_rack_env(headers: { 'X-API-Key' => 'valid_key' })
      env['rack.session'] = {}

      status, _headers, _body = wrapper.call(env)

      expect(status).to eq(200)
      expect(env['otto.strategy_result'].strategy_name).to eq('apikey')
    end

    it 'fails when all strategies fail' do
      env = mock_rack_env(headers: { 'Accept' => 'application/json' })
      env['rack.session'] = {}

      status, _headers, _body = wrapper.call(env)

      expect(status).to eq(401)
    end
  end

  describe 'role-based authorization' do
    let(:role_strategy) do
      Class.new do
        def authenticate(env, _requirement)
          session = env['rack.session']
          user_roles = session['user_roles'] || []
          Otto::Security::Authentication::StrategyResult.new(
            user: { id: 123, roles: user_roles },
            session: session,
            auth_method: 'session',
            metadata: {},
            strategy_name: nil
          )
        end
      end.new
    end

    let(:auth_config) do
      {
        auth_strategies: { 'session' => role_strategy },
      }
    end

    let(:route_definition) do
      Otto::RouteDefinition.new('GET', '/admin', 'Logic auth=session role=admin')
    end

    let(:wrapper) do
      described_class.new(mock_handler, route_definition, auth_config)
    end

    context 'with required role' do
      it 'allows access' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['admin'] }

        status, _headers, _body = wrapper.call(env)

        expect(status).to eq(200)
      end
    end

    context 'without required role' do
      it 'returns 403 for JSON requests' do
        env = mock_rack_env(headers: { 'Accept' => 'application/json' })
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['user'] }

        status, headers, body = wrapper.call(env)

        expect(status).to eq(403)
        expect(headers['content-type']).to eq('application/json')
        expect(JSON.parse(body.first)['error']).to eq('Forbidden')
      end

      it 'returns 403 for HTML requests' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['user'] }

        status, _headers, _body = wrapper.call(env)

        expect(status).to eq(403)
      end
    end

    context 'with OR logic for multiple roles' do
      let(:route_definition) do
        Otto::RouteDefinition.new('GET', '/content', 'Logic auth=session role=admin,editor')
      end

      it 'allows access with first role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['admin'] }

        status, _headers, _body = wrapper.call(env)

        expect(status).to eq(200)
      end

      it 'allows access with second role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['editor'] }

        status, _headers, _body = wrapper.call(env)

        expect(status).to eq(200)
      end

      it 'denies access without any required role' do
        env = mock_rack_env
        env['rack.session'] = { 'user_id' => 123, 'user_roles' => ['viewer'] }

        status, _headers, _body = wrapper.call(env)

        expect(status).to eq(403)
      end
    end
  end
end
```

### Testing Resource-Level Authorization (raise_concerns)

```ruby
# spec/logic/authorization_spec.rb
require 'spec_helper'

RSpec.describe 'Resource-Level Authorization' do
  let(:user_id) { 123 }
  let(:strategy_result) do
    Otto::Security::Authentication::StrategyResult.new(
      user: { id: user_id, roles: [] },
      session: { 'user_id' => user_id },
      auth_method: 'session',
      metadata: {},
      strategy_name: 'session'
    )
  end

  describe 'ownership-based authorization' do
    let(:post) { double('Post', id: 1, user_id: user_id) }

    context 'when user owns resource' do
      it 'allows access' do
        allow(Post).to receive(:find).and_return(post)
        logic = PostEditLogic.new(strategy_result, { id: 1 }, 'en')

        expect { logic.raise_concerns }.not_to raise_error
      end
    end

    context 'when user does not own resource' do
      let(:other_post) { double('Post', id: 2, user_id: 456) }

      it 'raises AuthorizationError' do
        allow(Post).to receive(:find).and_return(other_post)
        logic = PostEditLogic.new(strategy_result, { id: 2 }, 'en')

        expect { logic.raise_concerns }.to raise_error(
          Otto::Security::AuthorizationError,
          /Cannot edit another user's post/
        )
      end
    end
  end

  describe 'multi-condition authorization' do
    let(:organization) { double('Organization', id: 1, owner_id: 999) }
    let(:admin_strategy_result) do
      Otto::Security::Authentication::StrategyResult.new(
        user: { id: user_id, roles: ['admin'] },
        session: { 'user_id' => user_id, 'user_roles' => ['admin'] },
        auth_method: 'session',
        metadata: {},
        strategy_name: 'session'
      )
    end

    before do
      allow(Organization).to receive(:find).and_return(organization)
    end

    it 'allows admin access' do
      logic = OrganizationDeleteLogic.new(admin_strategy_result, { id: 1 }, 'en')

      expect { logic.raise_concerns }.not_to raise_error
    end

    it 'allows owner access' do
      owner_result = Otto::Security::Authentication::StrategyResult.new(
        user: { id: 999, roles: [] },
        session: { 'user_id' => 999 },
        auth_method: 'session',
        metadata: {},
        strategy_name: 'session'
      )
      logic = OrganizationDeleteLogic.new(owner_result, { id: 1 }, 'en')

      expect { logic.raise_concerns }.not_to raise_error
    end

    it 'denies access for non-admin, non-owner' do
      logic = OrganizationDeleteLogic.new(strategy_result, { id: 1 }, 'en')

      expect { logic.raise_concerns }.to raise_error(
        Otto::Security::AuthorizationError,
        /Requires admin role or organization ownership/
      )
    end
  end
end
```

## Request Specs (Full-Stack)

Full-stack tests through Rack for end-to-end validation.

### Basic Request Spec

```ruby
# spec/requests/dashboard_spec.rb
require 'spec_helper'

RSpec.describe 'Dashboard Requests', type: :request do
  let(:app) { MyOttoApp.new }

  describe 'GET /dashboard' do
    context 'when authenticated' do
      before do
        # Set up session
        env 'rack.session', { 'user_id' => 123 }
      end

      it 'returns 200 with dashboard data' do
        get '/dashboard'

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to include('application/json')

        data = JSON.parse(last_response.body)
        expect(data['user_id']).to eq(123)
      end

      it 'includes security headers' do
        get '/dashboard'

        expect(last_response.headers['x-content-type-options']).to eq('nosniff')
        expect(last_response.headers['x-xss-protection']).to eq('1; mode=block')
      end
    end

    context 'when not authenticated' do
      it 'redirects to login for HTML requests' do
        header 'Accept', 'text/html'
        get '/dashboard'

        expect(last_response.status).to eq(302)
        expect(last_response.headers['location']).to eq('/signin')
      end

      it 'returns 401 for JSON requests' do
        header 'Accept', 'application/json'
        get '/dashboard'

        expect(last_response.status).to eq(401)
        data = JSON.parse(last_response.body)
        expect(data['error']).to eq('Authentication Required')
      end
    end
  end
end
```

### Request Spec with API Key Authentication

```ruby
# spec/requests/api_spec.rb
require 'spec_helper'

RSpec.describe 'API Requests', type: :request do
  let(:app) { MyOttoApp.new }
  let(:valid_api_key) { 'test_api_key_123' }

  describe 'GET /api/data' do
    context 'with valid API key in header' do
      it 'returns 200 with data' do
        header 'X-API-Key', valid_api_key
        get '/api/data'

        expect(last_response.status).to eq(200)
        data = JSON.parse(last_response.body)
        expect(data).to have_key('results')
      end
    end

    context 'with valid API key in query parameter' do
      it 'returns 200 with data' do
        get "/api/data?api_key=#{valid_api_key}"

        expect(last_response.status).to eq(200)
      end
    end

    context 'with invalid API key' do
      it 'returns 401' do
        header 'X-API-Key', 'invalid_key'
        get '/api/data'

        expect(last_response.status).to eq(401)
        data = JSON.parse(last_response.body)
        expect(data['error']).to match(/Invalid API key/)
      end
    end

    context 'without API key' do
      it 'returns 401' do
        get '/api/data'

        expect(last_response.status).to eq(401)
      end
    end
  end
end
```

### Request Spec with Role-Based Access

```ruby
# spec/requests/admin_spec.rb
require 'spec_helper'

RSpec.describe 'Admin Requests', type: :request do
  let(:app) { MyOttoApp.new }

  describe 'GET /admin/users' do
    context 'with admin role' do
      before do
        env 'rack.session', {
          'user_id' => 123,
          'user_roles' => ['admin'],
        }
      end

      it 'returns 200 with user list' do
        get '/admin/users'

        expect(last_response.status).to eq(200)
        data = JSON.parse(last_response.body)
        expect(data['users']).to be_an(Array)
      end
    end

    context 'with non-admin role' do
      before do
        env 'rack.session', {
          'user_id' => 123,
          'user_roles' => ['user'],
        }
      end

      it 'returns 403' do
        header 'Accept', 'application/json'
        get '/admin/users'

        expect(last_response.status).to eq(403)
        data = JSON.parse(last_response.body)
        expect(data['error']).to eq('Forbidden')
      end
    end

    context 'without authentication' do
      it 'returns 401' do
        header 'Accept', 'application/json'
        get '/admin/users'

        expect(last_response.status).to eq(401)
      end
    end
  end
end
```

### Request Spec with Multi-Strategy Auth

```ruby
# spec/requests/multi_auth_spec.rb
require 'spec_helper'

RSpec.describe 'Multi-Strategy Auth Requests', type: :request do
  let(:app) { MyOttoApp.new }

  describe 'GET /protected' do
    context 'authenticates with session' do
      before do
        env 'rack.session', { 'user_id' => 123 }
      end

      it 'returns 200 and uses session strategy' do
        get '/protected'

        expect(last_response.status).to eq(200)
        # Strategy name is available in response if exposed
      end
    end

    context 'authenticates with API key when session absent' do
      it 'returns 200 and uses apikey strategy' do
        header 'X-API-Key', 'valid_key'
        get '/protected'

        expect(last_response.status).to eq(200)
      end
    end

    context 'both strategies fail' do
      it 'returns 401' do
        header 'Accept', 'application/json'
        get '/protected'

        expect(last_response.status).to eq(401)
      end
    end
  end
end
```

## Testing Error Handlers

Otto allows registering custom error handlers for expected business logic errors.

### Testing Error Handler Registration

```ruby
# spec/error_handling/registration_spec.rb
require 'spec_helper'

RSpec.describe 'Error Handler Registration' do
  class NotFoundError < StandardError; end
  class RateLimitError < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after: 60)
      super(message)
      @retry_after = retry_after
    end
  end

  let(:otto) { create_minimal_otto }

  describe '#register_error_handler' do
    it 'registers handler with status code' do
      otto.register_error_handler(NotFoundError, status: 404, log_level: :info)

      expect(otto.error_handlers['NotFoundError']).to include(
        status: 404,
        log_level: :info
      )
    end

    it 'registers handler with custom block' do
      custom_handler = lambda { |error, _req|
        { error: 'Custom', message: error.message }
      }

      otto.register_error_handler(NotFoundError, status: 404, &custom_handler)

      config = otto.error_handlers['NotFoundError']
      expect(config[:handler]).to eq(custom_handler)
    end

    it 'raises error when called after configuration freeze' do
      Otto.unfreeze_for_testing(otto)
      otto.send(:freeze_configuration!)

      expect {
        otto.register_error_handler(NotFoundError, status: 404)
      }.to raise_error(FrozenError, /Cannot modify frozen configuration/)
    end
  end

  describe 'error handler execution' do
    let(:env) { mock_rack_env(headers: { 'Accept' => 'application/json' }) }

    before do
      otto.register_error_handler(NotFoundError, status: 404, log_level: :info)
    end

    it 'returns configured status code' do
      error = NotFoundError.new('Resource not found')
      allow(Otto.logger).to receive(:info)

      response = otto.send(:handle_error, error, env)

      expect(response[0]).to eq(404)
    end

    it 'logs at configured level' do
      error = NotFoundError.new('Resource not found')

      expect(Otto).to receive(:structured_log).with(:info, 'Expected error in request', hash_including(
        error: 'Resource not found',
        error_class: 'NotFoundError',
        expected: true
      ))

      otto.send(:handle_error, error, env)
    end

    it 'returns JSON response for JSON requests' do
      error = NotFoundError.new('Resource not found')
      allow(Otto.logger).to receive(:info)

      response = otto.send(:handle_error, error, env)

      expect(response[1]['content-type']).to eq('application/json')
      body = JSON.parse(response[2].first)
      expect(body['error']).to eq('NotFoundError')
      expect(body['message']).to eq('Resource not found')
    end

    it 'uses custom handler block' do
      otto.register_error_handler(RateLimitError, status: 429) do |error, _req|
        {
          error: 'RateLimited',
          message: error.message,
          retry_after: error.retry_after,
        }
      end

      error = RateLimitError.new('Too many requests', retry_after: 120)
      allow(Otto.logger).to receive(:warn)

      response = otto.send(:handle_error, error, env)
      body = JSON.parse(response[2].first)

      expect(response[0]).to eq(429)
      expect(body['error']).to eq('RateLimited')
      expect(body['retry_after']).to eq(120)
    end

    it 'falls back to default response if custom handler fails' do
      otto.register_error_handler(NotFoundError, status: 404) do |_error, _req|
        raise StandardError, 'Handler failed'
      end

      error = NotFoundError.new('Resource not found')
      allow(Otto).to receive(:structured_log).with(:info, anything, anything)

      expect(Otto).to receive(:structured_log).with(:warn, 'Error in custom error handler', anything)

      response = otto.send(:handle_error, error, env)

      expect(response[0]).to eq(404)
    end

    it 'does not log backtrace for expected errors' do
      error = NotFoundError.new('Resource not found')
      allow(Otto).to receive(:structured_log)

      expect(Otto::LoggingHelpers).not_to receive(:log_backtrace)

      otto.send(:handle_error, error, env)
    end
  end

  describe 'unregistered errors' do
    class UnexpectedError < StandardError; end

    let(:env) { mock_rack_env(headers: { 'Accept' => 'application/json' }) }

    it 'handles as 500' do
      error = UnexpectedError.new('Something went wrong')
      allow(Otto.logger).to receive(:error)

      response = otto.send(:handle_error, error, env)

      expect(response[0]).to eq(500)
    end

    it 'logs at error level with backtrace' do
      error = UnexpectedError.new('Something went wrong')

      expect(Otto).to receive(:structured_log).with(:error, 'Unhandled error in request', anything)
      expect(Otto::LoggingHelpers).to receive(:log_backtrace)

      otto.send(:handle_error, error, env)
    end
  end
end
```

## Testing Middleware

### Testing IP Privacy Middleware

```ruby
# spec/middleware/ip_privacy_spec.rb
require 'spec_helper'

RSpec.describe Otto::Privacy::IPPrivacyMiddleware do
  let(:app) { ->(env) { [200, {}, ["Hello #{env['REMOTE_ADDR']}"]] } }
  let(:middleware) { described_class.new(app) }

  describe 'IP masking' do
    context 'with public IPv4' do
      it 'masks last octet' do
        env = mock_rack_env
        env['REMOTE_ADDR'] = '203.0.113.45'

        status, _headers, body = middleware.call(env)

        expect(status).to eq(200)
        expect(env['REMOTE_ADDR']).to eq('203.0.113.0')
        expect(body.first).to eq('Hello 203.0.113.0')
      end
    end

    context 'with private IPv4' do
      it 'does not mask' do
        env = mock_rack_env
        env['REMOTE_ADDR'] = '192.168.1.100'

        middleware.call(env)

        expect(env['REMOTE_ADDR']).to eq('192.168.1.100')
      end

      it 'does not mask localhost' do
        env = mock_rack_env
        env['REMOTE_ADDR'] = '127.0.0.1'

        middleware.call(env)

        expect(env['REMOTE_ADDR']).to eq('127.0.0.1')
      end
    end

    context 'with IPv6' do
      it 'masks public IPv6' do
        env = mock_rack_env
        env['REMOTE_ADDR'] = '2001:0db8:85a3::8a2e:0370:7334'

        middleware.call(env)

        expect(env['REMOTE_ADDR']).to match(/^2001:db8:85a3::/)
      end
    end
  end

  describe 'user agent anonymization' do
    it 'masks user agent string' do
      env = mock_rack_env(headers: {
        'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/91.0',
      })

      middleware.call(env)

      expect(env['HTTP_USER_AGENT']).not_to include('Windows NT 10.0')
      expect(env['HTTP_USER_AGENT']).to include('Chrome')
    end
  end

  describe 'referer sanitization' do
    it 'removes query parameters from referer' do
      env = mock_rack_env(headers: {
        'Referer' => 'https://example.com/page?session_id=abc123&user=john',
      })

      middleware.call(env)

      expect(env['HTTP_REFERER']).to eq('https://example.com/page')
    end
  end

  describe 'configuration options' do
    it 'respects masking level configuration' do
      middleware_level2 = described_class.new(app, masking_level: 2)
      env = mock_rack_env
      env['REMOTE_ADDR'] = '203.0.113.45'

      middleware_level2.call(env)

      expect(env['REMOTE_ADDR']).to eq('203.0.0.0')
    end

    it 'respects skip_private_ips configuration' do
      middleware_mask_all = described_class.new(app, skip_private_ips: false)
      env = mock_rack_env
      env['REMOTE_ADDR'] = '192.168.1.100'

      middleware_mask_all.call(env)

      expect(env['REMOTE_ADDR']).to eq('192.168.1.0')
    end
  end
end
```

### Testing CSRF Middleware

```ruby
# spec/middleware/csrf_spec.rb
require 'spec_helper'

RSpec.describe Otto::Security::CSRFMiddleware do
  let(:app) { ->(env) { [200, { 'Content-Type' => 'text/html' }, ['<html></html>']] } }
  let(:middleware) { described_class.new(app) }

  describe 'CSRF token validation' do
    context 'for safe methods (GET, HEAD, OPTIONS)' do
      it 'allows request without token' do
        env = mock_rack_env(method: 'GET')

        status, _headers, _body = middleware.call(env)

        expect(status).to eq(200)
      end
    end

    context 'for unsafe methods (POST, PUT, DELETE)' do
      it 'rejects request without token' do
        env = mock_rack_env(method: 'POST')
        env['rack.session'] = {}

        status, _headers, _body = middleware.call(env)

        expect(status).to eq(403)
      end

      it 'allows request with valid token' do
        env = mock_rack_env(method: 'POST')
        env['rack.session'] = { 'csrf_token' => 'valid_token' }
        env['HTTP_X_CSRF_TOKEN'] = 'valid_token'

        status, _headers, _body = middleware.call(env)

        expect(status).to eq(200)
      end

      it 'rejects request with invalid token' do
        env = mock_rack_env(method: 'POST')
        env['rack.session'] = { 'csrf_token' => 'valid_token' }
        env['HTTP_X_CSRF_TOKEN'] = 'invalid_token'

        status, _headers, _body = middleware.call(env)

        expect(status).to eq(403)
      end
    end
  end

  describe 'token injection' do
    it 'injects meta tag into HTML head' do
      env = mock_rack_env(method: 'GET')
      env['rack.session'] = { 'csrf_token' => 'test_token_123' }

      _status, _headers, body = middleware.call(env)

      html = body.first
      expect(html).to include('<meta name="csrf-token" content="test_token_123"')
    end

    it 'does not inject into non-HTML responses' do
      json_app = ->(env) { [200, { 'Content-Type' => 'application/json' }, ['{"data": "value"}']] }
      middleware = described_class.new(json_app)
      env = mock_rack_env(method: 'GET')
      env['rack.session'] = { 'csrf_token' => 'test_token' }

      _status, _headers, body = middleware.call(env)

      expect(body.first).not_to include('csrf-token')
    end
  end
end
```

## Shared Examples

Create reusable test patterns for common scenarios.

### Shared Examples for Authenticated Endpoints

```ruby
# spec/support/shared_examples/authenticated_endpoint.rb
RSpec.shared_examples 'an authenticated endpoint' do |method, path|
  context 'when not authenticated' do
    it 'returns 401 for JSON requests' do
      header 'Accept', 'application/json'
      send(method, path)

      expect(last_response.status).to eq(401)
      data = JSON.parse(last_response.body)
      expect(data['error']).to eq('Authentication Required')
    end

    it 'redirects to login for HTML requests' do
      header 'Accept', 'text/html'
      send(method, path)

      expect(last_response.status).to eq(302)
      expect(last_response.headers['location']).to eq('/signin')
    end
  end

  context 'when authenticated' do
    before do
      env 'rack.session', { 'user_id' => 123 }
    end

    it 'allows access' do
      send(method, path)

      expect(last_response.status).not_to eq(401)
      expect(last_response.status).not_to eq(302)
    end
  end
end

# Usage:
RSpec.describe 'Dashboard API' do
  include Rack::Test::Methods
  let(:app) { MyOttoApp.new }

  describe 'GET /dashboard' do
    it_behaves_like 'an authenticated endpoint', :get, '/dashboard'

    # Additional specific tests...
  end
end
```

### Shared Examples for Role-Protected Endpoints

```ruby
# spec/support/shared_examples/role_protected_endpoint.rb
RSpec.shared_examples 'a role-protected endpoint' do |method, path, required_role|
  context 'without authentication' do
    it 'returns 401' do
      header 'Accept', 'application/json'
      send(method, path)

      expect(last_response.status).to eq(401)
    end
  end

  context 'with authentication but without role' do
    before do
      env 'rack.session', {
        'user_id' => 123,
        'user_roles' => ['user'],
      }
    end

    it 'returns 403' do
      header 'Accept', 'application/json'
      send(method, path)

      expect(last_response.status).to eq(403)
      data = JSON.parse(last_response.body)
      expect(data['error']).to eq('Forbidden')
    end
  end

  context 'with authentication and required role' do
    before do
      env 'rack.session', {
        'user_id' => 123,
        'user_roles' => [required_role],
      }
    end

    it 'allows access' do
      send(method, path)

      expect(last_response.status).not_to eq(401)
      expect(last_response.status).not_to eq(403)
    end
  end
end

# Usage:
RSpec.describe 'Admin API' do
  include Rack::Test::Methods
  let(:app) { MyOttoApp.new }

  describe 'GET /admin/users' do
    it_behaves_like 'a role-protected endpoint', :get, '/admin/users', 'admin'

    # Additional specific tests...
  end
end
```

### Shared Examples for Resource Authorization

```ruby
# spec/support/shared_examples/resource_authorization.rb
RSpec.shared_examples 'resource ownership authorization' do |resource_class, logic_class|
  let(:owner_id) { 123 }
  let(:other_id) { 456 }

  let(:owner_context) do
    Otto::Security::Authentication::StrategyResult.new(
      user: { id: owner_id },
      session: { 'user_id' => owner_id },
      auth_method: 'session',
      metadata: {},
      strategy_name: 'session'
    )
  end

  let(:other_context) do
    Otto::Security::Authentication::StrategyResult.new(
      user: { id: other_id },
      session: { 'user_id' => other_id },
      auth_method: 'session',
      metadata: {},
      strategy_name: 'session'
    )
  end

  context 'when user owns resource' do
    it 'allows access' do
      resource = double(resource_class, id: 1, user_id: owner_id)
      allow(resource_class).to receive(:find).and_return(resource)

      logic = logic_class.new(owner_context, { id: 1 }, 'en')

      expect { logic.raise_concerns }.not_to raise_error
    end
  end

  context 'when user does not own resource' do
    it 'raises AuthorizationError' do
      resource = double(resource_class, id: 1, user_id: owner_id)
      allow(resource_class).to receive(:find).and_return(resource)

      logic = logic_class.new(other_context, { id: 1 }, 'en')

      expect { logic.raise_concerns }.to raise_error(Otto::Security::AuthorizationError)
    end
  end
end

# Usage:
RSpec.describe PostEditLogic do
  it_behaves_like 'resource ownership authorization', Post, PostEditLogic

  # Additional specific tests...
end
```

### Shared Examples for Security Headers

```ruby
# spec/support/shared_examples/security_headers.rb
RSpec.shared_examples 'response with security headers' do
  it 'includes X-Content-Type-Options header' do
    expect(last_response.headers['x-content-type-options']).to eq('nosniff')
  end

  it 'includes X-XSS-Protection header' do
    expect(last_response.headers['x-xss-protection']).to eq('1; mode=block')
  end

  it 'includes Referrer-Policy header' do
    expect(last_response.headers['referrer-policy']).to eq('strict-origin-when-cross-origin')
  end

  it 'includes X-Frame-Options header' do
    expect(last_response.headers['x-frame-options']).to eq('SAMEORIGIN')
  end
end

# Usage:
RSpec.describe 'API Endpoint' do
  describe 'GET /api/data' do
    before do
      header 'X-API-Key', 'valid_key'
      get '/api/data'
    end

    it_behaves_like 'response with security headers'
  end
end
```

## Best Practices

### 1. Test Authentication at Handler Level

Otto uses handler-level authentication via RouteAuthWrapper, not middleware:

```ruby
# Good - Test RouteAuthWrapper directly
let(:wrapper) do
  Otto::Security::Authentication::RouteAuthWrapper.new(
    handler, route_definition, auth_config
  )
end

# Avoid - Don't test authentication as middleware
# (Otto doesn't use middleware for authentication)
```

### 2. Use StrategyResult for Authentication State

Always use `env['otto.strategy_result']` for authentication state:

```ruby
# Good
result = env['otto.strategy_result']
expect(result).to be_authenticated
expect(result.user_id).to eq(123)

# Avoid - Don't read session directly
expect(env['rack.session']['user_id']).to eq(123)
```

### 3. Test Both Authorization Layers

Test both route-level and resource-level authorization:

```ruby
# Layer 1: Route-level (RouteAuthWrapper)
describe 'route authentication' do
  it 'requires admin role' do
    # Test RouteAuthWrapper with role=admin
  end
end

# Layer 2: Resource-level (Logic#raise_concerns)
describe '#raise_concerns' do
  it 'verifies resource ownership' do
    # Test Logic class authorization
  end
end
```

### 4. Use Factory Methods for Test Data

Create reusable factory methods for common test objects:

```ruby
# spec/support/factories.rb
module TestFactories
  def authenticated_result(user_id: 123, roles: [])
    Otto::Security::Authentication::StrategyResult.new(
      user: { id: user_id, roles: roles },
      session: { 'user_id' => user_id, 'user_roles' => roles },
      auth_method: 'session',
      metadata: {},
      strategy_name: 'session'
    )
  end

  def anonymous_result
    Otto::Security::Authentication::StrategyResult.anonymous
  end
end

RSpec.configure do |config|
  config.include TestFactories
end
```

### 5. Test Configuration Freezing

Verify configuration cannot be changed after first request:

```ruby
describe 'configuration freezing' do
  it 'prevents auth strategy changes after first request' do
    otto = Otto.new
    otto.call(mock_rack_env) # First request freezes config

    expect {
      otto.add_auth_strategy('new_strategy', strategy)
    }.to raise_error(FrozenError)
  end
end
```

### 6. Test IP Privacy by Default

Verify public IPs are masked while private IPs are preserved:

```ruby
describe 'IP privacy' do
  it 'masks public IPs' do
    env = mock_rack_env
    env['REMOTE_ADDR'] = '203.0.113.45'

    app.call(env)

    expect(env['REMOTE_ADDR']).to eq('203.0.113.0')
  end

  it 'preserves private IPs' do
    env = mock_rack_env
    env['REMOTE_ADDR'] = '192.168.1.100'

    app.call(env)

    expect(env['REMOTE_ADDR']).to eq('192.168.1.100')
  end
end
```

### 7. Test Multi-Strategy Authentication

Test OR logic for multiple authentication strategies:

```ruby
describe 'multi-strategy authentication' do
  let(:route) { 'Logic auth=session,apikey' }

  it 'succeeds with first strategy' do
    env['rack.session'] = { 'user_id' => 123 }
    # Should succeed without checking apikey
  end

  it 'tries second strategy when first fails' do
    env['HTTP_X_API_KEY'] = 'valid_key'
    # Should succeed with apikey when session absent
  end

  it 'fails only when all strategies fail' do
    # No session, no API key
    # Should return 401
  end
end
```

### 8. Use Descriptive Test Names

Write clear test names that explain what's being tested:

```ruby
# Good
it 'returns 403 when user lacks required role'
it 'allows admin access to organization owned by another user'
it 'masks last octet of public IPv4 addresses'

# Avoid
it 'works'
it 'handles authentication'
it 'tests the thing'
```

### 9. Test Error Handler Registration

Test both registration and execution of error handlers:

```ruby
describe 'error handlers' do
  it 'registers handler before first request' do
    otto.register_error_handler(NotFoundError, status: 404)
    expect(otto.error_handlers).to have_key('NotFoundError')
  end

  it 'executes handler and returns configured status' do
    otto.register_error_handler(NotFoundError, status: 404)
    # Trigger error and verify 404 response
  end

  it 'prevents registration after first request' do
    otto.call(env) # Freeze configuration
    expect {
      otto.register_error_handler(NotFoundError, status: 404)
    }.to raise_error(FrozenError)
  end
end
```

### 10. Test Logic Class Lifecycle

Test the complete Logic class lifecycle:

```ruby
describe PostCreateLogic do
  it 'follows complete lifecycle' do
    logic = described_class.new(context, params, locale)

    # 1. Validation
    expect { logic.raise_concerns }.not_to raise_error

    # 2. Processing
    result = logic.process
    expect(result).to be_a(Hash)

    # 3. Response formatting
    response = logic.response_data
    expect(response).to have_key(:post)
  end
end
```

## Summary

Otto 2 testing emphasizes:

1. **Handler-Level Authentication**: Test via RouteAuthWrapper, not middleware
2. **Two-Layer Authorization**: Test both route-level and resource-level checks
3. **Strategy Result Pattern**: Use `env['otto.strategy_result']` for auth state
4. **Full-Stack Testing**: Use Rack::Test for end-to-end validation
5. **Security by Default**: Verify IP privacy, security headers, and CSRF protection
6. **Configuration Freezing**: Test freeze after first request
7. **Multi-Strategy Auth**: Test OR logic for multiple auth strategies
8. **Logic Class Lifecycle**: Test raise_concerns, process, and response_data
9. **Error Handlers**: Test registration and execution of custom error handlers
10. **Shared Examples**: Create reusable patterns for common scenarios

This guide provides a comprehensive foundation for testing Otto 2 applications with confidence.
