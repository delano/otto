# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto::Route, 'enhanced route parsing' do
  describe '#initialize with enhanced parameters' do
    it 'parses traditional class method routes' do
      route = Otto::Route.new('GET', '/test', 'TestApp.index')

      expect(route.verb).to eq(:GET)
      expect(route.path).to eq('/test')
      expect(route.definition).to eq('TestApp.index')
      expect(route.route_options).to eq({})
      expect(route.klass.name).to eq('TestApp')
      expect(route.name).to eq('index')
      expect(route.kind).to eq(:class)
    end

    it 'parses traditional instance method routes' do
      route = Otto::Route.new('POST', '/create', 'TestApp#create')

      expect(route.verb).to eq(:POST)
      expect(route.path).to eq('/create')
      expect(route.definition).to eq('TestApp#create')
      expect(route.route_options).to eq({})
      expect(route.klass.name).to eq('TestApp')
      expect(route.name).to eq('create')
      expect(route.kind).to eq(:instance)
    end

    it 'parses enhanced routes with single parameter' do
      route = Otto::Route.new('POST', '/signin', 'TestApp.signin auth=authenticated')

      expect(route.verb).to eq(:POST)
      expect(route.path).to eq('/signin')
      expect(route.definition).to eq('TestApp.signin auth=authenticated')
      expect(route.route_options).to eq({ auth: 'authenticated' })
      expect(route.klass.name).to eq('TestApp')
      expect(route.name).to eq('signin')
      expect(route.kind).to eq(:class)
    end

    it 'parses enhanced routes with multiple parameters' do
      route = Otto::Route.new('GET', '/api/users', 'TestApp.api_users auth=api_key response=json csrf=exempt')

      expect(route.verb).to eq(:GET)
      expect(route.path).to eq('/api/users')
      expect(route.route_options).to eq({
                                          auth: 'api_key',
        response: 'json',
        csrf: 'exempt',
                                        })
      expect(route.klass.name).to eq('TestApp')
      expect(route.name).to eq('api_users')
      expect(route.kind).to eq(:class)
    end

    it 'parses enhanced routes with namespaced classes' do
      route = Otto::Route.new('GET', '/admin', 'V2::Logic::Admin::Panel auth=role:admin response=view')

      expect(route.route_options).to eq({
                                          auth: 'role:admin',
        response: 'view',
                                        })
      expect(route.klass.name).to eq('V2::Logic::Admin::Panel')
      expect(route.name).to eq('Panel')
      expect(route.kind).to eq(:class)
    end

    it 'handles malformed parameters gracefully' do
      # Parameters without = should be ignored
      route = Otto::Route.new('GET', '/test', 'TestApp.index badparam auth=authenticated')

      expect(route.route_options).to eq({ auth: 'authenticated' })
      expect(route.klass.name).to eq('TestApp')
    end

    it 'handles parameters with equals in values' do
      route = Otto::Route.new('GET', '/test', 'TestApp.index config=key=value')

      expect(route.route_options).to eq({ config: 'key=value' })
    end

    it 'handles empty parameter values' do
      route = Otto::Route.new('GET', '/test', 'TestApp.index empty=')

      expect(route.route_options).to eq({ empty: '' })
    end
  end

  describe '#call with route options' do
    let(:app) { create_minimal_otto(['GET /test TestApp.test auth=authenticated response=json']) }

    it 'makes route options available in env' do
      env = mock_rack_env(method: 'GET', path: '/test')

      # Capture the env that gets passed to the handler
      captured_env = nil
      allow(TestApp).to receive(:test) do |req, res|
        captured_env = req.env
        res.write('test response')
      end

      app.call(env)

      expect(captured_env['otto.route_options']).to eq({
                                                         auth: 'authenticated',
        response: 'json',
                                                       })
    end
  end
end
