# spec/otto/router_path_normalization_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Issue #187: dynamic-route and static-file dispatch used to match against the
# raw (unescape-only) path while literal matching and the LocalhostGuard used
# the normalized path (Otto::Utils.normalize_path). That divergence made
# dynamic routes stricter about trailing slashes than literal routes, and let
# invalid-UTF-8 bytes that are scrubbed for the guard survive into the dynamic
# matcher. All dispatch paths now share the single normalization.
RSpec.describe Otto, 'router path normalization (issue #187)' do
  let(:routes) do
    [
      'GET / TestApp.index',
      'GET /custom TestApp.custom_headers',
      'GET /show/:id TestApp.show',
      'GET /files/* TestApp.index',
    ]
  end

  let(:app) { create_minimal_otto(routes) }

  describe 'trailing-slash symmetry between literal and dynamic routes' do
    it 'matches a literal route with a trailing slash' do
      env = mock_rack_env(method: 'GET', path: '/custom/')
      response = app.call(env)

      expect(response[0]).to eq(200)
    end

    it 'matches a dynamic route with a trailing slash, like the literal one' do
      env = mock_rack_env(method: 'GET', path: '/show/123/')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Showing 123')
    end

    it 'still matches a dynamic route without a trailing slash' do
      env = mock_rack_env(method: 'GET', path: '/show/123')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Showing 123')
    end

    it 'captures the same param whether or not a trailing slash is present' do
      with_slash    = app.call(mock_rack_env(method: 'GET', path: '/show/abc/'))
      without_slash = app.call(mock_rack_env(method: 'GET', path: '/show/abc'))

      expect(with_slash[2].join).to eq(without_slash[2].join)
    end

    it 'applies the same normalization to HEAD (which is served by the GET dynamic route)' do
      # match_dynamic_route folds :GET routes into :HEAD, so a HEAD with a
      # trailing slash must normalize and match exactly like the GET route.
      env = mock_rack_env(method: 'HEAD', path: '/show/123/')
      response = app.call(env)

      expect(response[0]).to eq(200)
    end
  end

  describe 'root path handling after trailing-slash stripping' do
    # normalize_path collapses '/' to '' after stripping the trailing slash.
    # Dispatch restores '/' for the regex matcher so a catch-all still matches
    # root; literal lookup keeps '' since it already keys root that way.
    it 'still dispatches the root path to its literal route' do
      env = mock_rack_env(method: 'GET', path: '/')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Hello World')
    end

    it 'matches a catch-all splat route on a nested path' do
      env = mock_rack_env(method: 'GET', path: '/files/a/b')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Hello World')
    end

    it 'matches a catch-all splat route even when the root literal is absent' do
      splat_app = create_minimal_otto(['GET /* TestApp.index'])
      env = mock_rack_env(method: 'GET', path: '/')
      response = splat_app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Hello World')
    end
  end

  describe 'invalid-UTF-8 scrubbing before dynamic matching' do
    # A percent-encoded invalid byte (%FF) decodes to a byte the dynamic
    # matcher's UTF-8 regex would choke on. Matching against the raw path
    # raised mid-dispatch (500); matching against the scrubbed path drops the
    # byte and captures a clean param, consistent with literal matching and
    # the LocalhostGuard.
    it 'scrubs a percent-encoded invalid byte in a dynamic segment' do
      env = mock_rack_env(method: 'GET', path: '/show/abc%FF')
      response = app.call(env)

      expect(response[0]).to eq(200)
      expect(response[2].join).to eq('Showing abc')
    end
  end

  describe 'the static-file branch matches against the normalized path' do
    # The other half of the fix: safe_file? must receive the normalized
    # dispatch path, not the raw unescape-only path, so the static gate shares
    # the literal/guard normalization (trailing slash stripped, invalid bytes
    # scrubbed). safe_file? is stubbed to isolate the argument it is handed.
    let(:public_dir) { Dir.mktmpdir('otto_public') }

    let(:static_app) do
      File.write(File.join(public_dir, 'asset.txt'), 'body')
      otto = Otto.new(create_test_routes_file('static_norm.txt', ['GET / TestApp.index']),
                      public: public_dir)
      Otto.unfreeze_for_testing(otto)
      otto
    end

    after { FileUtils.remove_entry(public_dir) if File.directory?(public_dir) }

    it 'passes the trailing-slash-stripped path to safe_file?' do
      expect(static_app).to receive(:safe_file?).with('/asset.txt').and_return(false)
      static_app.call(mock_rack_env(method: 'GET', path: '/asset.txt/'))
    end

    it 'passes the invalid-byte-scrubbed path to safe_file?' do
      expect(static_app).to receive(:safe_file?).with('/asset.txt').and_return(false)
      static_app.call(mock_rack_env(method: 'GET', path: '/asset.txt%FF'))
    end
  end
end
