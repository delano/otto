# spec/otto/uri_duplicate_targets_spec.rb
#
# frozen_string_literal: true

# Issue #190: one definition string mounted at several verb/path pairs used
# to overwrite the single @route_definitions entry, so uri() returned
# whichever path loaded last. Reverse lookups now consult all routes per
# definition and pick by the params given.
require 'spec_helper'

RSpec.describe 'Otto#uri with duplicate targets (issue #190)' do
  subject(:otto) { Otto.new(routes_file) }

  let(:duplicate_target_routes) do
    [
      'GET /users/:id TestApp.show',
      'GET /me TestApp.show',
      'GET / TestApp.index',
    ]
  end

  let(:routes_file) { create_test_routes_file('test_routes_dup.txt', duplicate_target_routes) }

  describe 'reverse URI generation' do
    it 'picks the parameterized path when its params are given' do
      expect(otto.uri('TestApp.show', id: '123')).to eq('/users/123')
    end

    it 'picks the parameterless path when no params are given' do
      expect(otto.uri('TestApp.show')).to eq('/me')
    end

    it 'is independent of load order' do
      reversed_file = create_test_routes_file('test_routes_dup_rev.txt', [
                                                'GET /me TestApp.show',
                                                'GET /users/:id TestApp.show',
                                              ])
      reversed = Otto.new(reversed_file)

      expect(reversed.uri('TestApp.show', id: '123')).to eq('/users/123')
      expect(reversed.uri('TestApp.show')).to eq('/me')
    end

    it 'routes extra params to the query string of the selected path' do
      expect(otto.uri('TestApp.show', id: '123', page: '2')).to eq('/users/123?page=2')
    end

    it 'still generates URIs for unique definitions' do
      expect(otto.uri('TestApp.index')).to eq('/')
    end

    it 'still returns nil for unknown definitions' do
      expect(otto.uri('NonExistent.method')).to be_nil
    end
  end

  describe 'load-time diagnostics' do
    it 'warns when a definition string is loaded more than once' do
      allow(Otto).to receive(:structured_log)
      expect(Otto).to receive(:structured_log)
        .with(:warn, 'Duplicate route definition',
          hash_including(definition: 'TestApp.show', kept: 'GET /users/:id', also: 'GET /me'))

      Otto.new(routes_file)
    end
  end

  describe 'route_definitions determinism' do
    it 'keeps the first-loaded route per definition' do
      expect(otto.route_definitions['TestApp.show'].path).to eq('/users/:id')
    end

    it 'exposes every route per definition via routes_by_definition' do
      paths = otto.routes_by_definition['TestApp.show'].map(&:path)
      expect(paths).to eq(['/users/:id', '/me'])
    end
  end

  describe 'dispatch' do
    it 'still serves both paths' do
      env_me    = mock_rack_env(method: 'GET', path: '/me')
      env_users = mock_rack_env(method: 'GET', path: '/users/42')

      expect(otto.call(env_me)[0]).to eq(200)
      expect(otto.call(env_users)[0]).to eq(200)
    end
  end
end
