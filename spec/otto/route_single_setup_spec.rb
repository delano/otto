# spec/otto/route_single_setup_spec.rb
#
# frozen_string_literal: true

# Issue #189: with the handler factory present, Route#call used to build and
# decorate a req/res pair, then discard it when BaseHandler#call built its
# own from the same env and re-ran the identical setup. Request/response
# construction and param processing must happen exactly once per dispatch.
require 'spec_helper'

RSpec.describe 'Route dispatch single setup (issue #189)' do
  let(:routes) do
    [
      'GET / TestApp.index',
      'GET /show/:id TestApp.show',
    ]
  end

  let(:routes_file) { create_test_routes_file('test_routes_single_setup.txt', routes) }
  let(:otto) { Otto.new(routes_file) }

  it 'constructs exactly one request and one response per route dispatch' do
    # handle_request isolates route dispatch from Otto#call, which builds its
    # own top-level request for lifecycle hooks.
    allow(otto.request_class).to receive(:new).and_call_original
    allow(otto.response_class).to receive(:new).and_call_original

    otto.handle_request(mock_rack_env(method: 'GET', path: '/show/42'))

    expect(otto.request_class).to have_received(:new).once
    expect(otto.response_class).to have_received(:new).once
  end

  it 'processes params through indifferent_params exactly once per dispatch' do
    allow(Otto::Static).to receive(:indifferent_params).and_call_original

    otto.call(mock_rack_env(method: 'GET', path: '/show/42'))

    expect(Otto::Static).to have_received(:indifferent_params).once
  end

  describe 'behavior parity after consolidating setup in BaseHandler' do
    it 'still merges route path params into the request' do
      status, _headers, body = otto.call(mock_rack_env(method: 'GET', path: '/show/42'))

      expect(status).to eq(200)
      expect(body.join).to eq('Showing 42')
    end

    it 'still applies security headers to the response' do
      _status, headers, = otto.call(mock_rack_env(method: 'GET', path: '/'))

      expected = otto.security_config.security_headers
      expect(expected).not_to be_empty
      expected.each do |header, value|
        expect(headers[header]).to eq(value)
      end
    end

    it 'still exposes the route definition and options in env before the handler runs' do
      captured_env = nil
      allow(TestApp).to receive(:index) do |req, res|
        captured_env = req.env
        res.write('ok')
      end

      otto.call(mock_rack_env(method: 'GET', path: '/'))

      expect(captured_env['otto.route_definition']).to be_a(Otto::RouteDefinition)
      expect(captured_env['otto.route_definition'].definition).to eq('TestApp.index')
      expect(captured_env['otto.route_options']).to eq({})
    end
  end

  describe 'legacy fallback ordering (review follow-up)' do
    it 'builds req/res before populating env route keys, same as before #189' do
      # With no route_handler_factory, Route#call takes the legacy path.
      # A custom request_class#initialize reading env must keep seeing it
      # unpopulated, exactly as it did before the #189 refactor.
      otto.instance_variable_set(:@route_handler_factory, nil)

      route_definition_at_construction = :not_called
      allow(otto.request_class).to receive(:new).and_wrap_original do |original, env|
        route_definition_at_construction = env['otto.route_definition']
        original.call(env)
      end

      otto.call(mock_rack_env(method: 'GET', path: '/'))

      expect(route_definition_at_construction).to be_nil
    end
  end
end
