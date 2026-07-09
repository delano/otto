# spec/otto/route_loading_diagnostics_spec.rb
#
# frozen_string_literal: true

# Issue #191: malformed route lines and unparseable route options must not
# fail open silently. Skipped lines and dropped option tokens warn
# unconditionally; malformed security-gating options (auth/role/csrf) fail
# fast at load.
require 'spec_helper'

RSpec.describe 'Route loading diagnostics (issue #191)' do
  describe 'malformed route lines' do
    it 'warns when a line is missing its handler' do
      routes_file = create_test_routes_file('test_routes_no_handler.txt', ['GET /path'])

      allow(Otto).to receive(:structured_log)
      expect(Otto).to receive(:structured_log)
        .with(:warn, 'Malformed route line skipped', hash_including(line: 'GET /path'))

      Otto.new(routes_file)
    end

    it 'still skips the malformed line and loads the rest' do
      routes_file = create_test_routes_file('test_routes_partial.txt', [
                                              'GET /broken',
                                              'GET / TestApp.index',
                                            ])

      otto = Otto.new(routes_file)
      expect(otto.routes[:GET].size).to eq(1)
      expect(otto.routes[:GET].first.path).to eq('/')
    end
  end

  describe 'unparseable option tokens' do
    it 'warns (without Otto.debug) when a non-security option token has no value' do
      allow(Otto).to receive(:structured_log)
      expect(Otto).to receive(:structured_log)
        .with(:warn, 'Malformed route option ignored',
          hash_including(option: 'response', definition: 'TestApp.index response json'))
      expect(Otto).to receive(:structured_log)
        .with(:warn, 'Malformed route option ignored',
          hash_including(option: 'json', definition: 'TestApp.index response json'))

      route = Otto::Route.new('GET', '/test', 'TestApp.index response json')
      expect(route.route_options).to eq({})
    end

    it 'still stores well-formed options alongside a dropped token' do
      allow(Otto).to receive(:structured_log)
      route = Otto::Route.new('GET', '/test', 'TestApp.index badparam auth=authenticated')
      expect(route.route_options).to eq({ auth: 'authenticated' })
    end

    it 'preserves empty values for non-security options' do
      route = Otto::Route.new('GET', '/test', 'TestApp.index empty=')
      expect(route.route_options).to eq({ empty: '' })
    end
  end

  describe 'security-gating options fail fast' do
    %w[auth role csrf].each do |option|
      it "raises Otto::RouteDefinitionError for a bare `#{option}` token" do
        expect do
          Otto::Route.new('GET', '/test', "TestApp.index #{option}")
        end.to raise_error(Otto::RouteDefinitionError, /#{option}=value/)
      end

      it "raises Otto::RouteDefinitionError for an empty `#{option}=` value" do
        expect do
          Otto::Route.new('GET', '/test', "TestApp.index #{option}=")
        end.to raise_error(Otto::RouteDefinitionError, /#{option}=value/)
      end
    end

    it 'raises for `csrf exempt` (missing =) instead of serving with CSRF enabled silently' do
      expect do
        Otto::Route.new('GET', '/test', 'TestApp.index csrf exempt')
      end.to raise_error(Otto::RouteDefinitionError)
    end

    it 'propagates out of Otto#load so boot fails instead of dropping the route' do
      routes_file = create_test_routes_file('test_routes_bad_auth.txt', [
                                              'GET /admin TestApp.index auth',
                                            ])

      expect { Otto.new(routes_file) }.to raise_error(Otto::RouteDefinitionError)
    end

    it 'accepts well-formed security options' do
      route = Otto::Route.new('GET', '/test', 'TestApp.index auth=session csrf=exempt role=admin')
      expect(route.route_options).to eq({ auth: 'session', csrf: 'exempt', role: 'admin' })
    end
  end
end
