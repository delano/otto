# spec/otto/core/router_head_dispatch_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# HEAD dispatch used to fold the GET tables into the registered HEAD tables
# (routes_literal[:HEAD].merge! and routes[:HEAD].push) on every HEAD request
# once any HEAD route was declared. Against a frozen configuration, the state
# the first request outside RSpec leaves behind, that raised FrozenError and
# every HEAD request returned 500. Unfrozen, the merge let the GET handler
# replace a declared HEAD handler and grew routes[:HEAD] on every request.
#
# Otto#call skips the lazy freeze under RSpec, so the frozen examples freeze
# explicitly. A HEAD response has an empty body (spec/otto/head_response_spec.rb),
# so each handler names itself in an x-handler header.
RSpec.describe Otto::Core::Router do
  before do
    stub_const('HeadDispatchApp', Module.new do
      { index: 'Hello World', test: 'test response', search: 'Search results' }.each do |name, text|
        define_singleton_method(name) do |_req, res|
          res.headers['x-handler'] = name.to_s
          res.write(text)
        end
      end

      define_singleton_method(:show) do |req, res|
        res.headers['x-handler'] = 'show'
        res.write("Showing #{req.params['id']}")
      end

      define_singleton_method(:update) do |req, res|
        res.headers['x-handler'] = 'update'
        res.write("Updated #{req.params['id']}")
      end
    end)
  end

  let(:routes) do
    [
      'GET /health HeadDispatchApp.index',
      'HEAD /health HeadDispatchApp.test',
      'GET /other HeadDispatchApp.search',
      'GET /show/:id HeadDispatchApp.show',
      'GET /items/:id HeadDispatchApp.show',
      'HEAD /items/:id HeadDispatchApp.update',
    ]
  end

  let(:routes_file) { create_test_routes_file('head_dispatch.txt', routes) }
  let(:app) { Otto.new(routes_file) }

  def head(path)
    app.call(mock_rack_env(method: 'HEAD', path: path))
  end

  def body_of(response)
    response[2].to_enum(:each).to_a.join
  end

  def handler_of(response)
    response[1]['x-handler']
  end

  def table_sizes
    {
      literal_head: app.routes_literal[:HEAD].size,
       literal_get: app.routes_literal[:GET].size,
       routes_head: app.routes[:HEAD].size,
        routes_get: app.routes[:GET].size,
    }
  end

  context 'with the configuration frozen' do
    before { app.freeze_configuration! }

    it 'freezes the route tables' do
      expect(app.frozen_configuration?).to be true
      expect(app.routes[:HEAD]).to be_frozen
      expect(app.routes_literal[:HEAD]).to be_frozen
    end

    it 'serves HEAD to a declared HEAD literal path with the HEAD handler' do
      response = head('/health')

      expect(response[0]).to eq(200)
      expect(handler_of(response)).to eq('test')
    end

    it 'falls back to the GET handler for a GET-only literal path' do
      response = head('/other')

      expect(response[0]).to eq(200)
      expect(handler_of(response)).to eq('search')
    end

    it 'falls back to the GET handler for a GET-only dynamic path' do
      response = head('/show/123')

      expect(response[0]).to eq(200)
      expect(handler_of(response)).to eq('show')
    end

    it 'tries a declared HEAD dynamic route before the GET dynamic route' do
      response = head('/items/7')

      expect(response[0]).to eq(200)
      expect(handler_of(response)).to eq('update')
    end

    it 'keeps serving GET requests with the GET handler' do
      response = app.call(mock_rack_env(method: 'GET', path: '/health'))

      expect(response[0]).to eq(200)
      expect(body_of(response)).to eq('Hello World')
    end

    it 'does not fall back to the GET route for other methods' do
      expect(app.call(mock_rack_env(method: 'POST', path: '/other'))[0]).to eq(404)
      expect(app.call(mock_rack_env(method: 'POST', path: '/show/1'))[0]).to eq(404)
    end

    it 'answers repeated HEAD requests without error' do
      statuses = Array.new(3) { %w[/health /other /show/1].map { |path| head(path)[0] } }

      expect(statuses.flatten.uniq).to eq([200])
    end
  end

  context 'without freezing (the RSpec default)' do
    it 'uses the declared HEAD handler instead of the GET handler for the same path' do
      expect(handler_of(head('/health'))).to eq('test')
      expect(handler_of(head('/health'))).to eq('test')
    end

    it 'does not change the route table sizes after repeated HEAD requests' do
      before_sizes = table_sizes

      3.times do
        head('/health')
        head('/other')
        head('/show/1')
        head('/items/1')
        head('/missing')
      end

      expect(table_sizes).to eq(before_sizes)
    end

    it 'does not create a HEAD table when no HEAD route is declared' do
      get_only = Otto.new(create_test_routes_file('head_get_only.txt', ['GET /other HeadDispatchApp.search']))

      response = get_only.call(mock_rack_env(method: 'HEAD', path: '/other'))

      expect(response[0]).to eq(200)
      expect(get_only.routes).not_to have_key(:HEAD)
      expect(get_only.routes_literal).not_to have_key(:HEAD)
    end
  end

  context 'with a GET /404 route' do
    let(:routes) do
      [
        'GET /404 HeadDispatchApp.search',
        'HEAD /health HeadDispatchApp.test',
      ]
    end

    before { app.freeze_configuration! }

    it 'uses the GET /404 route for an unmatched HEAD request' do
      response = head('/missing')

      expect(response[0]).to eq(200)
      expect(handler_of(response)).to eq('search')
    end

    it 'does not use the GET /404 route for an unmatched POST request' do
      response = app.call(mock_rack_env(method: 'POST', path: '/missing'))

      expect(response[0]).to eq(404)
      expect(handler_of(response)).to be_nil
    end
  end

  context 'with both HEAD /404 and GET /404 routes' do
    let(:routes) do
      [
        'GET /404 HeadDispatchApp.search',
        'HEAD /404 HeadDispatchApp.test',
      ]
    end

    before { app.freeze_configuration! }

    it 'uses the HEAD /404 route for an unmatched HEAD request' do
      response = head('/missing')

      expect(response[0]).to eq(200)
      expect(handler_of(response)).to eq('test')
    end

    it 'keeps using the GET /404 route for an unmatched GET request' do
      response = app.call(mock_rack_env(method: 'GET', path: '/missing'))

      expect(response[0]).to eq(200)
      expect(body_of(response)).to eq('Search results')
    end
  end

  # A HEAD request with no HEAD route falls back to the GET route, and the GET
  # route's options come with it: the fallback must not skip its auth= gate.
  context 'with a GET-only route that requires auth' do
    let(:routes) { ['GET /secret HeadDispatchApp.search auth=apikey'] }

    before do
      app.add_auth_strategy('apikey',
        Otto::Security::Authentication::Strategies::APIKeyStrategy.new(api_keys: ['head-key']))
      app.freeze_configuration!
    end

    def head_secret(headers = {})
      app.call(mock_rack_env(method: 'HEAD', path: '/secret',
        headers: { 'Accept' => 'application/json' }.merge(headers)))
    end

    it 'rejects an unauthenticated HEAD request that falls back to the GET route' do
      expect(head_secret[0]).to eq(401)
    end

    it 'serves the fallback when the HEAD request authenticates' do
      response = head_secret('X-API-Key' => 'head-key')

      expect(response[0]).to eq(200)
      expect(handler_of(response)).to eq('search')
    end
  end

  # A declared HEAD route runs with its own options. It does not inherit
  # auth= or role= from the GET route for the same path.
  context 'with a declared HEAD route next to a GET route that requires auth' do
    let(:routes) do
      [
        'GET /secret HeadDispatchApp.search auth=apikey',
        'HEAD /secret HeadDispatchApp.test',
      ]
    end

    before do
      app.add_auth_strategy('apikey',
        Otto::Security::Authentication::Strategies::APIKeyStrategy.new(api_keys: ['head-key']))
      app.freeze_configuration!
    end

    it 'serves the declared HEAD route without the GET route auth= gate' do
      response = head('/secret')

      expect(response[0]).to eq(200)
      expect(handler_of(response)).to eq('test')
    end

    it 'keeps the auth= gate on the GET route' do
      response = app.call(mock_rack_env(method: 'GET', path: '/secret',
        headers: { 'Accept' => 'application/json' }))

      expect(response[0]).to eq(401)
    end
  end
end
