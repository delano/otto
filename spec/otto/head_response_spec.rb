# spec/otto/head_response_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'rack/lint'

# The Rack SPEC requires an empty body for a HEAD request, and Rack::Lint
# enforces it. Otto dispatches HEAD to the declared HEAD route or falls back
# to the GET route, so the handler writes the GET body; Otto#call must drop
# that body, close it, and keep the headers (Rack::Head semantics).
RSpec.describe Otto do # rubocop:disable RSpec/SpecFilePathFormat
  describe '#call with a HEAD request' do
    let(:closable_body) do
      Class.new do
        attr_reader :chunks

        def initialize(*chunks)
          @chunks = chunks
          @closed = false
        end

        def each(&) = @chunks.each(&)

        def close
          @closed = true
        end

        def closed? = @closed
      end
    end

    let(:routes) do
      [
        'GET /page HeadResponseApp.page',
        'HEAD /probe HeadResponseApp.probe',
        'GET /show/:id HeadResponseApp.show',
        'GET /boom HeadResponseApp.boom',
        'GET /sized HeadResponseApp.sized',
        'GET /closable HeadResponseApp.closable',
      ]
    end

    let(:app) { described_class.new(create_test_routes_file('head_response.txt', routes)) }
    let(:linted) { Rack::Lint.new(app) }

    before do
      body_class = closable_body
      stub_const('HeadResponseApp', Module.new do
        define_singleton_method(:page) do |_req, res|
          res.headers['content-type'] = 'text/plain'
          res.headers['x-page'] = 'yes'
          res.write('page body')
        end
        define_singleton_method(:probe) { |_req, res| res.write('probe body') }
        define_singleton_method(:show) { |req, res| res.write("show #{req.params['id']}") }
        define_singleton_method(:boom) { |_req, _res| raise 'boom' }
        define_singleton_method(:sized) do |_req, res|
          res.headers['content-length'] = '11'
          res.body = ['hello world']
        end
        define_singleton_method(:closable) do |_req, res|
          res.body = HeadResponseApp.last_body = body_class.new('closable body')
        end
        singleton_class.attr_accessor :last_body
      end)
    end

    # Drive a request through Rack::Lint the way a server would: iterate the
    # body, then close it. Lint raises Rack::Lint::LintError on any violation.
    def lint_call(method, path)
      status, headers, body = linted.call(Rack::MockRequest.env_for(path, method: method))
      content = +''
      body.each { |chunk| content << chunk }
      body.close
      [status, headers, content]
    end

    it 'hands request completion hooks the response with the empty body' do
      seen = []
      app.on_request_complete { |_req, res, _duration| seen << [res.status, res.body.to_enum(:each).to_a] }

      app.call(mock_rack_env(method: 'HEAD', path: '/page'))

      expect(seen).to eq([[200, []]])
    end

    context 'with the configuration frozen' do
      before { app.freeze_configuration! }

      it 'returns an empty body for a HEAD request that falls back to a GET literal route' do
        status, headers, body = lint_call('HEAD', '/page')

        expect(status).to eq(200)
        expect(headers['x-page']).to eq('yes')
        expect(headers['content-type']).to eq('text/plain')
        expect(body).to eq('')
      end

      it 'still returns the body for the GET request' do
        expect(lint_call('GET', '/page')[2]).to eq('page body')
      end

      it 'returns an empty body for a declared HEAD route' do
        status, _headers, body = lint_call('HEAD', '/probe')

        expect(status).to eq(200)
        expect(body).to eq('')
      end

      it 'returns an empty body for a HEAD request that falls back to a GET dynamic route' do
        status, _headers, body = lint_call('HEAD', '/show/7')

        expect(status).to eq(200)
        expect(body).to eq('')
      end

      it 'keeps the content-length the handler set' do
        status, headers, body = lint_call('HEAD', '/sized')

        expect(status).to eq(200)
        expect(headers['content-length']).to eq('11')
        expect(body).to eq('')
      end

      it 'returns an empty body for an unmatched HEAD request' do
        status, _headers, body = lint_call('HEAD', '/missing')

        expect(status).to eq(404)
        expect(body).to eq('')
      end

      it 'returns an empty body when the handler raises' do
        status, _headers, body = lint_call('HEAD', '/boom')

        expect(status).to eq(500)
        expect(body).to eq('')
      end

      it 'closes the body the handler returned' do
        _status, _headers, body = app.call(mock_rack_env(method: 'HEAD', path: '/closable'))

        expect(body.to_enum(:each).to_a).to eq([])
        expect(HeadResponseApp.last_body).to be_closed
      end

      it 'leaves the body of a GET request open for the server to close' do
        _status, _headers, body = app.call(mock_rack_env(method: 'GET', path: '/closable'))

        expect(body.to_enum(:each).to_a.join).to eq('closable body')
        expect(HeadResponseApp.last_body).not_to be_closed
      end
    end
  end
end
