# spec/otto/head_response_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'rack/lint'

# Rack::Lint rejects a response body for a HEAD request ("Response body was
# given for HEAD request, but should be empty", rack/lint.rb). Otto dispatches
# HEAD to the declared HEAD route or falls back to the GET route, so the
# handler writes the GET body. Otto#call must return an empty body, keep the
# headers, and close the handler's body when the server closes the returned
# one, as it would for GET.
RSpec.describe Otto do # rubocop:disable RSpec/SpecFilePathFormat
  describe '#call with a HEAD request' do
    let(:raising_close_body) do
      Class.new do
        def each
          yield 'x'
        end

        def close
          raise IOError, 'close failed'
        end
      end
    end

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
        'GET /raising HeadResponseApp.raising_close',
      ]
    end

    let(:app) { described_class.new(create_test_routes_file('head_response.txt', routes)) }
    let(:linted) { Rack::Lint.new(app) }

    before do
      body_class = closable_body
      raising_class = raising_close_body
      stub_const('HeadResponseApp', Module.new do
        define_singleton_method(:raising_close) { |_req, res| res.body = raising_class.new }
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

    it 'hands request completion hooks the empty body when closing the original would raise' do
      seen = []
      app.on_request_complete { |_req, res, _duration| seen << [res.status, res.body.to_enum(:each).to_a] }

      app.call(mock_rack_env(method: 'HEAD', path: '/raising'))

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

      it 'closes the body the handler returned when the server closes the response body' do
        _status, _headers, body = app.call(mock_rack_env(method: 'HEAD', path: '/closable'))

        expect(body.to_enum(:each).to_a).to eq([])
        expect(HeadResponseApp.last_body).not_to be_closed

        body.close

        expect(HeadResponseApp.last_body).to be_closed
      end

      it 'does not raise from Otto#call when closing the handler body raises' do
        status, _headers, body = app.call(mock_rack_env(method: 'HEAD', path: '/raising'))

        expect(status).to eq(200)
        expect(body.to_enum(:each).to_a).to eq([])
      end

      it 'raises the close error where the server closes the response body, as for GET' do
        _status, _headers, body = app.call(mock_rack_env(method: 'HEAD', path: '/raising'))

        expect { body.close }.to raise_error(IOError, 'close failed')
      end

      it 'leaves the body of a GET request open for the server to close' do
        _status, _headers, body = app.call(mock_rack_env(method: 'GET', path: '/closable'))

        expect(body.to_enum(:each).to_a.join).to eq('closable body')
        expect(HeadResponseApp.last_body).not_to be_closed
      end
    end

    # The static stages answer HEAD with the headers GET would get, so a
    # client can check an asset's size and type without downloading it.
    context 'with a public directory and a static mount' do
      let(:public_dir) { Dir.mktmpdir('otto_head_public') }
      let(:mount_dir) { Dir.mktmpdir('otto_head_mount') }
      let(:app) do
        otto = described_class.new(create_test_routes_file('head_static.txt', routes), public: public_dir)
        otto.mount_static('/assets', root: mount_dir)
        otto
      end

      before do
        File.write(File.join(public_dir, 'asset.txt'), 'asset content')
        File.write(File.join(mount_dir, 'app.css'), 'body{}')
        app.freeze_configuration!
      end

      after do
        FileUtils.remove_entry(public_dir)
        FileUtils.remove_entry(mount_dir)
      end

      it 'serves the headers of a public-directory file with an empty body' do
        status, headers, body = lint_call('HEAD', '/asset.txt')

        expect(status).to eq(200)
        expect(headers['content-length']).to eq('13')
        expect(headers['content-type']).to eq('text/plain')
        expect(body).to eq('')
      end

      it 'serves the headers of a mounted file with an empty body' do
        status, headers, body = lint_call('HEAD', '/assets/app.css')

        expect(status).to eq(200)
        expect(headers['content-length']).to eq('6')
        expect(headers['content-type']).to eq('text/css')
        expect(body).to eq('')
      end

      it 'falls through to not found for a missing file' do
        status, _headers, body = lint_call('HEAD', '/assets/missing.css')

        expect(status).to eq(404)
        expect(body).to eq('')
      end

      it 'still serves the files to GET' do
        expect(lint_call('GET', '/asset.txt')[2]).to eq('asset content')
        expect(lint_call('GET', '/assets/app.css')[2]).to eq('body{}')
      end

      it 'still does not serve the files to POST' do
        expect(lint_call('POST', '/asset.txt')[0]).to eq(404)
        expect(lint_call('POST', '/assets/app.css')[0]).to eq(404)
      end
    end
  end
end
