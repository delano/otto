# spec/otto/security/csrf_enforcement_wrapper_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Handler-layer CSRF enforcement (issue #186). Enforcement moved off the global
# CSRFMiddleware (which runs ahead of route matching and could not see
# `csrf=exempt`) to this wrapper, which runs after matching where the route
# definition — and thus `csrf_exempt?` — is available.
RSpec.describe Otto::Security::CSRFEnforcementWrapper do
  let(:config) do
    cfg = Otto::Security::Config.new
    cfg.enable_csrf_protection!
    cfg
  end

  # Sentinel handler: any successful call returns 200 so a pass-through is
  # distinguishable from a 403 block.
  let(:inner) { ->(_env, _extra = {}) { [200, { 'content-type' => 'text/plain' }, ['handled']] } }

  let(:route_definition) { Otto::RouteDefinition.new('POST', '/guarded', 'TestApp.create') }
  let(:exempt_definition) { Otto::RouteDefinition.new('POST', '/webhook', 'TestApp.create csrf=exempt') }

  let(:wrapper) { described_class.new(inner, route_definition, config) }

  describe 'safe methods' do
    %w[GET HEAD OPTIONS TRACE].each do |method|
      it "passes #{method} through without a token" do
        env = mock_rack_env(method: method, path: '/guarded')
        expect(wrapper.call(env)[0]).to eq(200)
      end
    end
  end

  describe 'unsafe methods on a non-exempt route' do
    %w[POST PUT DELETE PATCH].each do |method|
      let(:route_definition) { Otto::RouteDefinition.new(method, '/guarded', 'TestApp.create') }

      it "rejects #{method} without a token (403 JSON)" do
        env = mock_rack_env(method: method, path: '/guarded')
        response = wrapper.call(env)

        expect(response[0]).to eq(403)
        expect(response[1]['content-type']).to eq('application/json')
        body = JSON.parse(response[2].join)
        expect(body['error']).to eq('CSRF token validation failed')
        expect(response[1]['content-length'].to_i).to eq(response[2].join.bytesize)
      end

      it "rejects #{method} with an invalid token" do
        env = mock_rack_env(method: method, path: '/guarded', params: { '_csrf_token' => 'invalid:token' })
        expect(wrapper.call(env)[0]).to eq(403)
      end

      it "accepts #{method} with a valid token in params" do
        session_id = 'sess-params'
        token = config.generate_csrf_token(session_id)
        env = mock_rack_env(method: method, path: '/guarded', params: { '_csrf_token' => token })
        env['rack.session'] = { 'session_id' => session_id }

        expect(wrapper.call(env)[0]).to eq(200)
      end

      it "accepts #{method} with a valid token in the header" do
        session_id = 'sess-header'
        token = config.generate_csrf_token(session_id)
        env = mock_rack_env(method: method, path: '/guarded', headers: { 'X-CSRF-Token' => token })
        env['rack.session'] = { 'session_id' => session_id }

        expect(wrapper.call(env)[0]).to eq(200)
      end

      it "accepts #{method} with the AJAX alternative header" do
        session_id = 'sess-ajax'
        token = config.generate_csrf_token(session_id)
        env = mock_rack_env(method: method, path: '/guarded')
        env['HTTP_X_REQUESTED_WITH'] = 'XMLHttpRequest'
        env['HTTP_X_CSRF_TOKEN'] = token
        env['rack.session'] = { 'session_id' => session_id }

        expect(wrapper.call(env)[0]).to eq(200)
      end
    end

    it 'rejects an empty token parameter' do
      env = mock_rack_env(method: 'POST', path: '/guarded', params: { '_csrf_token' => '' })
      expect(wrapper.call(env)[0]).to eq(403)
    end

    it 'rejects a whitespace-only token parameter' do
      env = mock_rack_env(method: 'POST', path: '/guarded', params: { '_csrf_token' => '   ' })
      expect(wrapper.call(env)[0]).to eq(403)
    end
  end

  describe 'csrf=exempt route' do
    let(:wrapper) { described_class.new(inner, exempt_definition, config) }

    it 'passes an unsafe request through without a token' do
      env = mock_rack_env(method: 'POST', path: '/webhook')
      expect(wrapper.call(env)[0]).to eq(200)
    end

    it 'does not require a token even when one would be invalid' do
      env = mock_rack_env(method: 'POST', path: '/webhook', params: { '_csrf_token' => 'invalid:token' })
      expect(wrapper.call(env)[0]).to eq(200)
    end
  end

  describe 'when CSRF protection is disabled' do
    let(:config) { Otto::Security::Config.new } # disabled by default

    it 'passes unsafe requests through without a token' do
      env = mock_rack_env(method: 'POST', path: '/guarded')
      expect(wrapper.call(env)[0]).to eq(200)
    end
  end

  describe 'extra_params passthrough' do
    it 'forwards extra_params to the wrapped handler on exempt routes' do
      seen = nil
      handler = lambda do |_env, extra = {}|
        seen = extra
        [200, {}, ['ok']]
      end
      wrapper = described_class.new(handler, exempt_definition, config)

      wrapper.call(mock_rack_env(method: 'POST', path: '/webhook'), { 'id' => '7' })
      expect(seen).to eq('id' => '7')
    end
  end
end
