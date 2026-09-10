# spec/otto/fallback_response_isolation_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'rack/response'
require 'rack/headers'

# Fallback response isolation (#272): a static not_found / server_error triple
# must never be handed back to the Rack stack by reference, and both
# writers accept a per-request callable.
RSpec.describe Otto do
  # Commits a cookie the way rack-session's commit_session does: wrap the
  # returned headers in Rack::Response::Raw and call #set_cookie, which
  # appends via Rack::Utils.set_cookie_header! when a value already exists.
  let(:cookie_committer) do
    Class.new do
      def initialize(app, name: 'sid')
        @app  = app
        @name = name
      end

      def call(env)
        status, headers, body = @app.call(env)
        Rack::Response::Raw.new(status, headers).set_cookie(@name, value: env.fetch('test.cookie', 'v'))
        [status, headers, body]
      end
    end
  end

  let(:static_headers) { { 'content-type' => 'application/json' } }
  let(:not_found_triple) { [404, static_headers, ['{"error":"Not Found"}']] }
  let(:server_error_triple) { [500, static_headers, ['{"error":"Internal Server Error"}']] }

  let(:otto) { create_minimal_otto }

  def miss(app, path = '/nope', cookie: nil)
    env = mock_rack_env(path: path)
    env['test.cookie'] = cookie if cookie
    app.call(env)
  end

  def cookies_in(response)
    Array(response[1]['set-cookie'])
  end

  before do
    allow(described_class.logger).to receive(:info)
    allow(described_class.logger).to receive(:warn)
    allow(described_class.logger).to receive(:error)
    allow(described_class.logger).to receive(:debug)
  end

  shared_examples 'a fallback response writer' do |writer|
    let(:reader) { writer }

    it 'accepts a Rack triple' do
      otto.public_send(:"#{writer}=", not_found_triple)
      expect(otto.public_send(reader)).to equal(not_found_triple)
    end

    it 'accepts a proc, a lambda, a Method and any object responding to #call' do
      handler = Class.new { def call(_env) = [404, {}, []] }.new
      [proc { |_env| not_found_triple }, ->(_env) { not_found_triple }, handler, handler.method(:call)].each do |callable|
        otto.public_send(:"#{writer}=", callable)
        expect(otto.public_send(reader)).to equal(callable)
      end
    end

    it 'accepts nil to restore the built-in response' do
      otto.public_send(:"#{writer}=", not_found_triple)
      otto.public_send(:"#{writer}=", nil)
      expect(otto.public_send(reader)).to be_nil
    end

    it 'rejects a String' do
      expect { otto.public_send(:"#{writer}=", 'Not Found') }
        .to raise_error(ArgumentError, /#{writer} must be a Rack triple/)
    end

    it 'rejects an Array that is not a triple' do
      expect { otto.public_send(:"#{writer}=", [404, {}]) }.to raise_error(ArgumentError)
      expect { otto.public_send(:"#{writer}=", [404, {}, [], :extra]) }.to raise_error(ArgumentError)
    end

    it 'rejects a triple whose headers are not a Hash-like' do
      expect { otto.public_send(:"#{writer}=", [404, 'content-type: text/plain', []]) }
        .to raise_error(ArgumentError)
    end

    it 'rejects a triple whose status is not an Integer' do
      expect { otto.public_send(:"#{writer}=", ['404', {}, []]) }.to raise_error(ArgumentError)
    end

    it 'leaves the previous value in place when rejecting' do
      otto.public_send(:"#{writer}=", not_found_triple)
      expect { otto.public_send(:"#{writer}=", 42) }.to raise_error(ArgumentError)
      expect(otto.public_send(reader)).to equal(not_found_triple)
    end
  end

  describe '#not_found=' do
    it_behaves_like 'a fallback response writer', :not_found
  end

  describe '#server_error=' do
    it_behaves_like 'a fallback response writer', :server_error
  end

  describe 'Otto::Static.copy_response' do
    it 'returns a new triple sharing no mutable container with the original' do
      original = [404, { 'x-list' => %w[a b], 'x-one' => '1' }, ['body']]
      copy = Otto::Static.copy_response(original)

      expect(copy).to eq(original)
      expect(copy).not_to equal(original)
      expect(copy[1]).not_to equal(original[1])
      expect(copy[1]['x-list']).not_to equal(original[1]['x-list'])
      expect(copy[2]).not_to equal(original[2])
    end

    it 'keeps the headers class so Rack::Headers stays case-insensitive' do
      headers = Rack::Headers.new
      headers['Content-Type'] = 'text/plain'
      copy = Otto::Static.copy_response([404, headers, []])

      expect(copy[1]).to be_a(Rack::Headers)
      expect(copy[1]['CONTENT-TYPE']).to eq('text/plain')
    end

    it 'returns writable containers for a frozen triple' do
      frozen = [404, { 'x-list' => %w[a].freeze }.freeze, ['body'].freeze].freeze
      copy = Otto::Static.copy_response(frozen)

      expect(copy[1]).not_to be_frozen
      expect(copy[1]['x-list']).not_to be_frozen
      expect(copy[2]).not_to be_frozen
      expect { copy[1]['set-cookie'] = 'sid=1' }.not_to raise_error
    end

    it 'leaves a non-Array body untouched' do
      body = Object.new
      expect(Otto::Static.copy_response([200, {}, body])[2]).to equal(body)
    end

    it 'substitutes an empty Hash for nil headers' do
      expect(Otto::Static.copy_response([204, nil, []])[1]).to eq({})
    end
  end

  describe 'static not_found triple' do
    before { otto.not_found = not_found_triple }

    it 'returns an equal but distinct triple on every miss' do
      first  = miss(otto)
      second = miss(otto)

      expect(first).to eq(not_found_triple)
      expect(first).not_to equal(not_found_triple)
      expect(first[1]).not_to equal(static_headers)
      expect(first[1]).not_to equal(second[1])
      expect(first[2]).not_to equal(not_found_triple[2])
    end

    it 'does not expose the configured headers to in-place writes' do
      miss(otto)[1]['set-cookie'] = 'sid=leaked'
      expect(static_headers).not_to have_key('set-cookie')
    end

    it 'copies Array-valued headers so an append cannot reach the shared Array' do
      otto.not_found = [404, { 'set-cookie' => ['a=1'] }, []]
      miss(otto)[1]['set-cookie'] << 'b=2'

      expect(otto.not_found[1]['set-cookie']).to eq(['a=1'])
      expect(miss(otto)[1]['set-cookie']).to eq(['a=1'])
    end

    it 'preserves a Rack::Headers container' do
      headers = Rack::Headers.new
      headers['Content-Type'] = 'text/html'
      otto.not_found = [404, headers, ['<h1>Nope</h1>']]

      response = miss(otto)
      expect(response[1]).to be_a(Rack::Headers)
      expect(response[1]['content-type']).to eq('text/html')
      expect(response[1]).not_to equal(headers)
    end

    it 'still serves a frozen triple once cookie middleware writes headers' do
      otto.not_found = [404, { 'content-type' => 'text/plain' }.freeze, ['gone'].freeze].freeze
      app = cookie_committer.new(otto)

      expect(cookies_in(miss(app))).to eq(['sid=v'])
    end

    context 'when cookie middleware is mounted above Otto' do
      let(:app) { cookie_committer.new(otto) }

      it 'returns exactly one Set-Cookie per miss and never replays an earlier one' do
        first  = miss(app, cookie: 'first-session')
        second = miss(app, cookie: 'second-session')

        expect(cookies_in(first)).to eq(['sid=first-session'])
        expect(cookies_in(second)).to eq(['sid=second-session'])
        expect(second[1].to_s).not_to include('first-session')
      end

      it 'leaves the configured triple untouched afterwards' do
        3.times { |i| miss(app, cookie: "s#{i}") }

        expect(static_headers).to eq('content-type' => 'application/json')
        expect(otto.not_found).to eq([404, { 'content-type' => 'application/json' }, ['{"error":"Not Found"}']])
      end

      it 'isolates concurrent misses from each other' do
        responses = Array.new(16) do |i|
          Thread.new { miss(app, cookie: "t#{i}") } # rubocop:disable ThreadSafety/NewThread
        end.map(&:value)

        responses.each_with_index do |response, i|
          expect(cookies_in(response)).to eq(["sid=t#{i}"])
        end
        expect(static_headers).not_to have_key('set-cookie')
      end
    end

    context "when the cookie is committed by Otto's own middleware stack" do
      before { otto.use(cookie_committer, name: 'inner') }

      it 'returns exactly one Set-Cookie per miss' do
        first  = miss(otto, cookie: 'one')
        second = miss(otto, cookie: 'two')

        expect(cookies_in(first)).to eq(['inner=one'])
        expect(cookies_in(second)).to eq(['inner=two'])
        expect(static_headers).not_to have_key('set-cookie')
      end
    end

    context "when Otto's CSRF middleware sets the session cookie" do
      let(:otto) { create_secure_otto(csrf_protection: true, request_validation: false) }
      let(:html_headers) { { 'content-type' => 'text/html' } }

      before { otto.not_found = [404, html_headers, ['<html><head></head><body>Nope</body></html>']] }

      it 'sets a single session cookie per miss and leaves the configured triple clean' do
        first  = miss(otto)
        second = miss(otto)

        expect(cookies_in(first).length).to eq(1)
        expect(cookies_in(second).length).to eq(1)
        expect(cookies_in(first).first).to start_with('_otto_session=')
        expect(cookies_in(second).first).not_to eq(cookies_in(first).first)
        expect(html_headers).not_to have_key('set-cookie')
        expect(otto.not_found[2]).to eq(['<html><head></head><body>Nope</body></html>'])
      end
    end
  end

  describe 'not_found callable' do
    it 'is invoked with the Rack env on every miss' do
      seen = []
      otto.not_found = lambda do |env|
        seen << env['PATH_INFO']
        [404, { 'content-type' => 'text/plain' }, ["No #{env['PATH_INFO']}"]]
      end

      expect(miss(otto, '/a')[2]).to eq(['No /a'])
      expect(miss(otto, '/b')[2]).to eq(['No /b'])
      expect(seen).to eq(['/a', '/b'])
    end

    it 'accepts an object responding to #call' do
      handler = Class.new do
        def call(env) = [404, { 'x-path' => env['PATH_INFO'] }, []]
      end.new
      otto.not_found = handler

      expect(miss(otto, '/obj')[1]['x-path']).to eq('/obj')
    end

    it 'copies a triple the callable returns, so a memoized triple is still isolated' do
      shared = [404, { 'content-type' => 'text/plain' }, ['memo']]
      otto.not_found = ->(_env) { shared }
      app = cookie_committer.new(otto)

      expect(cookies_in(miss(app, cookie: 'a'))).to eq(['sid=a'])
      expect(cookies_in(miss(app, cookie: 'b'))).to eq(['sid=b'])
      expect(shared[1]).not_to have_key('set-cookie')
    end

    it 'turns a raising callable into a 500 through the error handler' do
      otto.not_found = ->(_env) { raise 'boom' }

      response = miss(otto)
      expect(response[0]).to eq(500)
      expect(response[2].join).to match(/error/i)
      expect(described_class.logger).to have_received(:error).with(/Unhandled error in request.*boom/)
    end

    it 'turns a callable returning a non-triple into a 500' do
      otto.not_found = ->(_env) { 'Not Found' }

      response = miss(otto)
      expect(response[0]).to eq(500)
      expect(described_class.logger).to have_received(:error).with(/not_found callable must return a Rack triple/)
    end
  end

  describe 'not_found precedence' do
    it 'uses the built-in response, fresh per call, when nothing is configured' do
      first  = miss(otto)
      second = miss(otto)

      expect(first[0]).to eq(404)
      expect(first[2]).to eq(['Not Found'])
      expect(first[1]).not_to equal(second[1])
    end

    it 'restores the built-in response after assigning nil' do
      otto.not_found = not_found_triple
      otto.not_found = nil

      expect(miss(otto)[2]).to eq(['Not Found'])
    end

    it 'prefers a GET /404 route over the configured fallback' do
      stub_const('FallbackTestApp', Class.new do
        def self.missing(_req, res)
          res.write('routed 404')
        end
      end)
      otto = create_minimal_otto(['GET /404 FallbackTestApp.missing'])
      calls = 0
      otto.not_found = lambda do |_env|
        calls += 1
        not_found_triple
      end

      expect(miss(otto)[2].join).to eq('routed 404')
      expect(calls).to eq(0)
    end

    it 'is not consulted for a matched route' do
      stub_const('FallbackTestApp', Class.new do
        def self.index(_req, res)
          res.write('hit')
        end
      end)
      otto = create_minimal_otto(['GET /hit FallbackTestApp.index'])
      otto.not_found = ->(_env) { raise 'should not be called' }

      expect(miss(otto, '/hit')[2].join).to eq('hit')
    end
  end

  describe 'server_error' do
    let(:otto) do
      stub_const('FallbackTestApp', Class.new do
        def self.boom(_req, _res)
          raise 'kaboom'
        end
      end)
      create_minimal_otto(['GET /boom FallbackTestApp.boom'])
    end

    def boom(app, cookie: nil, accept: nil)
      env = mock_rack_env(path: '/boom')
      env['test.cookie'] = cookie if cookie
      env['HTTP_ACCEPT'] = accept if accept
      app.call(env)
    end

    context 'with a static triple' do
      before { otto.server_error = server_error_triple }

      it 'returns an equal but distinct triple on every error' do
        first  = boom(otto)
        second = boom(otto)

        expect(first).to eq(server_error_triple)
        expect(first).not_to equal(server_error_triple)
        expect(first[1]).not_to equal(static_headers)
        expect(first[1]).not_to equal(second[1])
      end

      it 'returns exactly one Set-Cookie per error through cookie middleware' do
        app = cookie_committer.new(otto)

        expect(cookies_in(boom(app, cookie: 'one'))).to eq(['sid=one'])
        expect(cookies_in(boom(app, cookie: 'two'))).to eq(['sid=two'])
        expect(static_headers).not_to have_key('set-cookie')
      end

      it 'still returns the built-in JSON error body to JSON clients' do
        response = boom(otto, accept: 'application/json')

        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('application/json')
        expect(response[2].join).to include('Internal Server Error')
        expect(response[2]).not_to eq(server_error_triple[2])
      end

      it 'yields to a GET /500 route' do
        stub_const('FallbackTestApp', Class.new do
          def self.boom(_req, _res)
            raise 'kaboom'
          end

          def self.error_page(req, res)
            res.write("custom #{req.env['otto.error_id']}")
          end
        end)
        otto = create_minimal_otto(['GET /boom FallbackTestApp.boom', 'GET /500 FallbackTestApp.error_page'])
        otto.server_error = server_error_triple

        expect(boom(otto)[2].join).to match(/\Acustom [a-f0-9]{16}\z/)
      end
    end

    context 'with a callable' do
      it 'receives env and the error when it takes two arguments' do
        received = nil
        otto.server_error = lambda do |env, error|
          received = [env['PATH_INFO'], error]
          [500, { 'content-type' => 'text/plain' }, ["failed #{env['otto.error_id']}"]]
        end

        response = boom(otto)
        expect(received[0]).to eq('/boom')
        expect(received[1]).to be_a(RuntimeError).and have_attributes(message: 'kaboom')
        expect(response[2].join).to match(/\Afailed [a-f0-9]{16}\z/)
      end

      it 'receives only env when it takes one argument' do
        otto.server_error = ->(env) { [500, {}, [env['otto.error_id']]] }

        expect(boom(otto)[2].join).to match(/\A[a-f0-9]{16}\z/)
      end

      it 'accepts an object whose #call takes env and error' do
        handler = Class.new do
          def call(_env, error) = [503, { 'content-type' => 'text/plain' }, [error.message]]
        end.new
        otto.server_error = handler

        response = boom(otto)
        expect(response[0]).to eq(503)
        expect(response[2]).to eq(['kaboom'])
      end

      it 'accepts a proc with optional arguments' do
        otto.server_error = proc { |*args| [500, {}, [args.length.to_s]] }

        expect(boom(otto)[2]).to eq(['2'])
      end

      it 'is invoked fresh on every error' do
        calls = 0
        otto.server_error = lambda do |_env, _error|
          calls += 1
          [500, {}, [calls.to_s]]
        end

        expect(boom(otto)[2]).to eq(['1'])
        expect(boom(otto)[2]).to eq(['2'])
      end

      it 'copies the triple it returns' do
        shared = [500, {}, ['memo']]
        otto.server_error = ->(_env, _error) { shared }
        app = cookie_committer.new(otto)

        expect(cookies_in(boom(app, cookie: 'a'))).to eq(['sid=a'])
        expect(cookies_in(boom(app, cookie: 'b'))).to eq(['sid=b'])
        expect(shared[1]).to eq({})
      end

      it 'falls back to the built-in secure response and logs when it raises' do
        otto.server_error = ->(_env, _error) { raise 'handler broke' }

        response = boom(otto)
        expect(response[0]).to eq(500)
        expect(response[1]['content-type']).to eq('text/plain')
        expect(response[2].join).to match(/An error occurred|Server error/)
        expect(described_class.logger).to have_received(:error).with(/Error in server_error fallback.*handler broke/)
      end

      it 'falls back to the built-in secure response when it returns a non-triple' do
        otto.server_error = ->(_env, _error) {}

        response = boom(otto)
        expect(response[0]).to eq(500)
        expect(response[2].join).to match(/An error occurred|Server error/)
        expect(described_class.logger).to have_received(:error).with(/server_error callable must return a Rack triple/)
      end
    end

    it 'uses the built-in secure response, fresh per call, when nothing is configured' do
      first  = boom(otto)
      second = boom(otto)

      expect(first[0]).to eq(500)
      expect(first[2].join).to match(/An error occurred|Server error/)
      expect(first[1]).not_to equal(second[1])
    end
  end
end
