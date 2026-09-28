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
# explicitly.
RSpec.describe Otto::Core::Router do
  let(:routes) do
    [
      'GET /health TestApp.index',
      'HEAD /health TestApp.test',
      'GET /other TestApp.search',
      'GET /show/:id TestApp.show',
      'GET /items/:id TestApp.show',
      'HEAD /items/:id TestApp.update',
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
      expect(body_of(response)).to eq('test response')
    end

    it 'falls back to the GET handler for a GET-only literal path' do
      response = head('/other')

      expect(response[0]).to eq(200)
      expect(body_of(response)).to eq('Search results')
    end

    it 'falls back to the GET handler for a GET-only dynamic path' do
      response = head('/show/123')

      expect(response[0]).to eq(200)
      expect(body_of(response)).to eq('Showing 123')
    end

    it 'tries a declared HEAD dynamic route before the GET dynamic route' do
      response = head('/items/7')

      expect(response[0]).to eq(200)
      expect(body_of(response)).to eq('Updated 7')
    end

    it 'keeps serving GET requests with the GET handler' do
      response = app.call(mock_rack_env(method: 'GET', path: '/health'))

      expect(response[0]).to eq(200)
      expect(body_of(response)).to eq('Hello World')
    end

    it 'answers repeated HEAD requests without error' do
      statuses = Array.new(3) { %w[/health /other /show/1].map { |path| head(path)[0] } }

      expect(statuses.flatten.uniq).to eq([200])
    end
  end

  context 'without freezing (the RSpec default)' do
    it 'uses the declared HEAD handler instead of the GET handler for the same path' do
      expect(body_of(head('/health'))).to eq('test response')
      expect(body_of(head('/health'))).to eq('test response')
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
      get_only = Otto.new(create_test_routes_file('head_get_only.txt', ['GET /other TestApp.search']))

      response = get_only.call(mock_rack_env(method: 'HEAD', path: '/other'))

      expect(response[0]).to eq(200)
      expect(get_only.routes).not_to have_key(:HEAD)
      expect(get_only.routes_literal).not_to have_key(:HEAD)
    end
  end

  context 'with a GET /404 route' do
    let(:routes) do
      [
        'GET /404 TestApp.search',
        'HEAD /health TestApp.test',
      ]
    end

    before { app.freeze_configuration! }

    it 'uses the GET /404 route for an unmatched HEAD request' do
      response = head('/missing')

      expect(response[0]).to eq(200)
      expect(body_of(response)).to eq('Search results')
    end
  end
end
