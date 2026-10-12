# spec/otto/security/csrf_middleware_rack_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# CSRFMiddleware's responses checked against Rack::Lint, for HTML and other
# responses, HTML bodies it may not read (files and streams), 204 and 304
# responses and HEAD requests, and a binding that is not a hex token.
# Rack::Lint raises Rack::Lint::LintError on any violation of the Rack
# specification.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'CSRFMiddleware and the Rack specification' do
  include OttoTestHelpers

  let(:config) do
    Otto::Security::Config.new.tap do |c|
      c.enable_csrf_protection!
      c.csrf_secret = '7' * 64
    end
  end

  let(:html) { '<html><head></head><body>form</body></html>' }

  def env_for(url, method: 'GET', cookie: nil, session: nil)
    Rack::MockRequest.env_for(url, method: method).tap do |env|
      env['HTTP_COOKIE']  = cookie if cookie
      env['rack.session'] = session if session
    end
  end

  # Drives the middleware through Rack::Lint the way a server would: iterate
  # the body, then close it.
  def lint_call(app, url = 'https://example.org/', **env_options)
    stack = Rack::Lint.new(Otto::Security::Middleware::CSRFMiddleware.new(app, config))
    status, headers, body = stack.call(env_for(url, **env_options))
    content = +''
    body.each { |chunk| content << chunk }
    body.close
    [status, headers, content]
  end

  def binding_cookies(headers)
    Array(headers['set-cookie']).grep(/\A(?:__Host-otto_session|_otto_session)=/)
  end

  # An app that mints a binding the way a token endpoint does, and returns
  # new headers and body on every call.
  def minting_app(status, headers, body)
    lambda do |env|
      config.get_or_create_session_id(Otto::Request.new(env))
      [status, headers.dup, body.dup]
    end
  end

  describe 'an HTML response' do
    it 'passes Rack::Lint with the injected token, cookie and Content-Length' do
      app = ->(_env) { [200, { 'content-type' => 'text/html', 'content-length' => html.bytesize.to_s }, [html]] }

      status, headers, content = lint_call(app)

      expect(status).to eq(200)
      expect(content).to include('<meta name="csrf-token"')
      expect(headers['content-length']).to eq(content.bytesize.to_s)
      expect(binding_cookies(headers).size).to eq(1)
    end

    it 'passes Rack::Lint when the app returns a frozen response and frozen headers' do
      app = ->(_env) { [200, { 'content-type' => 'text/html' }.freeze, [html]].freeze }

      _, headers, content = lint_call(app)

      expect(content).to include('<meta name="csrf-token"')
      expect(headers['cache-control']).to eq('private')
    end

    # Rack::Lint on both sides also checks how the middleware treats the
    # app's body: Rack lets middleware read a body through #to_ary, which
    # closes it.
    it 'injects the token into a body it may only read through #to_ary, and closes that body' do
      app = Rack::Lint.new(->(_env) { [200, { 'content-type' => 'text/html' }, [html]] })

      _, headers, content = lint_call(app)

      expect(content).to include('<meta name="csrf-token"')
      expect(binding_cookies(headers).size).to eq(1)
    end

    it 'closes a body proxy it replaces' do
      closed = false
      app = ->(_env) { [200, { 'content-type' => 'text/html' }, Rack::BodyProxy.new([html]) { closed = true }] }

      _, _, content = lint_call(app)

      expect(content).to include('<meta name="csrf-token"')
      expect(closed).to be(true)
    end

    it 'passes Rack::Lint when the page has no <head>' do
      app = Rack::Lint.new(->(_env) { [200, { 'content-type' => 'text/html' }, ['<p>no head</p>']] })

      _, headers, content = lint_call(app)

      expect(content).to eq('<p>no head</p>')
      expect(binding_cookies(headers).size).to eq(1)
    end

    # Middleware may not read a body that lacks #to_ary, so such a body gets
    # no token and is passed on unread. It still gets the binding cookie.
    it 'passes on a body without #to_ary unread' do
      each_only = Class.new do
        def initialize(content) = @content = content
        def each = yield(@content)
      end
      app = Rack::Lint.new(->(_env) { [200, { 'content-type' => 'text/html' }, each_only.new(html)] })

      status, headers, content = lint_call(app)

      expect(status).to eq(200)
      expect(content).to eq(html)
      expect(binding_cookies(headers).size).to eq(1)
      expect(headers['cache-control']).to eq('private')
    end

    it 'passes on a streaming body unread' do
      stream_body = lambda do |stream|
        stream.write(html)
        stream.close
      end
      app   = Rack::Lint.new(->(_env) { [200, { 'content-type' => 'text/html' }, stream_body] })
      stack = Rack::Lint.new(Otto::Security::Middleware::CSRFMiddleware.new(app, config))

      status, headers, body = stack.call(env_for('https://example.org/'))
      stream = StringIO.new
      body.call(stream)

      expect(status).to eq(200)
      expect(stream.string).to eq(html)
      expect(binding_cookies(headers).size).to eq(1)
    end

    # A HEAD response has an empty body, so there is no <head> to inject
    # into. The binding cookie is still set, as on any HTML response,
    # whatever the request method.
    it 'passes Rack::Lint on a HEAD request' do
      app = Rack::Lint.new(lambda do |_env|
        [200, { 'content-type' => 'text/html', 'content-length' => html.bytesize.to_s }, []]
      end)

      status, headers, content = lint_call(app, method: 'HEAD')

      expect(status).to eq(200)
      expect(content).to be_empty
      expect(headers['content-length']).to eq(html.bytesize.to_s)
      expect(binding_cookies(headers).size).to eq(1)
    end
  end

  describe 'a response that is not HTML' do
    it 'passes Rack::Lint with the binding cookie' do
      app = Rack::Lint.new(minting_app(200, { 'content-type' => 'application/json', 'content-length' => '2' }, ['{}']))

      _, headers, content = lint_call(app)

      expect(content).to eq('{}')
      expect(binding_cookies(headers).size).to eq(1)
    end

    it 'passes Rack::Lint when the app returns a frozen response and frozen headers' do
      app = lambda do |env|
        config.get_or_create_session_id(Otto::Request.new(env))
        [200, { 'content-type' => 'application/json' }.freeze, ['{}']].freeze
      end

      _, headers, = lint_call(app)

      expect(binding_cookies(headers).size).to eq(1)
      expect(headers['cache-control']).to eq('private')
    end

    [204, 304].each do |status|
      it "passes Rack::Lint on a #{status} response, adding no body, Content-Type or Content-Length" do
        app = Rack::Lint.new(minting_app(status, {}, []))

        returned_status, headers, content = lint_call(app)

        expect(returned_status).to eq(status)
        expect(content).to be_empty
        expect(headers.keys).to contain_exactly('set-cookie', 'cache-control')
        expect(binding_cookies(headers).size).to eq(1)
      end
    end

    it 'passes Rack::Lint on a HEAD request' do
      app = Rack::Lint.new(minting_app(200, { 'content-type' => 'application/json', 'content-length' => '2' }, []))

      _, headers, content = lint_call(app, method: 'HEAD')

      expect(content).to be_empty
      expect(headers['content-length']).to eq('2')
      expect(binding_cookies(headers).size).to eq(1)
    end
  end

  # Otto#call empties the body of a HEAD response after its middleware ran,
  # so the HEAD response advertises the Content-Length of the GET response,
  # injected token included.
  describe 'through Otto#call' do
    let(:otto) do
      handlers = {
        'page' => lambda do |_req, res, _extra|
          res['content-type'] = 'text/html'
          res.write('<html><head></head><body></body></html>')
        end,
        'empty' => lambda do |req, res, _extra|
          req.env['otto.security_config'].get_or_create_session_id(req)
          res.status = 204
        end,
      }
      routes = create_test_routes_file('test_routes_csrf_middleware_rack.txt', ['GET /page &page', 'GET /empty &empty'])
      Otto.new(routes, lambda_handlers: handlers, csrf_protection: true).tap do |app|
        app.security_config.csrf_secret = '8' * 64
      end
    end

    def otto_lint_call(method, path)
      status, headers, body = Rack::Lint.new(otto).call(env_for("https://example.org#{path}", method: method))
      content = +''
      body.each { |chunk| content << chunk }
      body.close
      [status, headers, content]
    end

    it 'gives a HEAD request the headers of the GET response and an empty body' do
      _, get_headers, get_content = otto_lint_call('GET', '/page')
      _, head_headers, head_content = otto_lint_call('HEAD', '/page')

      expect(head_content).to be_empty
      expect(head_headers['content-length']).to eq(get_content.bytesize.to_s)
      expect(get_headers['content-length']).to eq(get_content.bytesize.to_s)
      expect(binding_cookies(head_headers).size).to eq(1)
    end

    it 'passes Rack::Lint on a 204 that sets the binding cookie' do
      status, headers, content = otto_lint_call('GET', '/empty')

      expect(status).to eq(204)
      expect(content).to be_empty
      expect(binding_cookies(headers).size).to eq(1)
    end
  end

  # Rack::Files, which serves public: and mount_static, returns a body that
  # does not respond to #to_ary, and its responses pass through
  # CSRFMiddleware.
  describe 'an HTML file from the public directory' do
    let(:public_dir) { Dir.mktmpdir('otto_csrf_public') }
    let(:otto) do
      routes = create_test_routes_file('test_routes_csrf_middleware_public.txt', ['GET /dynamic &dynamic'])
      handlers = { 'dynamic' => ->(_req, res, _extra) { res.write('dynamic') } }
      Otto.new(routes, public: public_dir, lambda_handlers: handlers, csrf_protection: true).tap do |app|
        app.security_config.csrf_secret = '9' * 64
      end
    end

    before { File.write(File.join(public_dir, 'page.html'), html) }
    after { FileUtils.rm_rf(public_dir) }

    def get_page(cookie: nil)
      status, headers, body = Rack::Lint.new(otto).call(env_for('https://example.org/page.html', cookie: cookie))
      content = +''
      body.each { |chunk| content << chunk }
      body.close
      [status, headers, content]
    end

    it 'is served unchanged, with the binding cookie on a first visit' do
      status, headers, content = get_page

      expect(status).to eq(200)
      expect(content).to eq(html)
      expect(binding_cookies(headers).size).to eq(1)
      expect(headers['cache-control']).to eq('private')
    end

    it 'is served unchanged, with no cookie or Cache-Control once the client sends the cookie' do
      _, first, = get_page
      status, headers, content = get_page(cookie: binding_cookies(first).first.split(';').first)

      expect(status).to eq(200)
      expect(content).to eq(html)
      expect(binding_cookies(headers)).to be_empty
      expect(headers['cache-control']).to be_nil
    end
  end

  # Rack URL-decodes cookie values, and the middleware URL-encodes the
  # binding it writes. A binding that is not a hex token, here a value
  # stored under csrf_session_key with a space, ';' and '%', must read back
  # unchanged, or the cookie would be set again on every response.
  describe 'a binding that is not a hex token' do
    let(:binding_value) { 'a b;c%41' }
    let(:session) { { config.csrf_session_key => binding_value } }

    def cookie_header(headers) = binding_cookies(headers).first.split(';').first

    schemes = %w[https http]
    {
      'HTML' => [{ 'content-type' => 'text/html' }, '<html><head></head></html>'],
      'JSON' => [{ 'content-type' => 'application/json' }, '{}'],
    }.each do |kind, (app_headers, app_body)|
      schemes.each do |scheme|
        it "is set once on #{kind} over #{scheme.upcase} and not again once the client sends it back" do
          app = Rack::Lint.new(minting_app(200, app_headers, [app_body]))
          url = "#{scheme}://example.org/"

          _, first, = lint_call(app, url, session: session)

          expect(binding_cookies(first).size).to eq(1)
          expect(cookie_header(first)).to end_with('=a+b%3Bc%2541')

          _, second, = lint_call(app, url, session: session, cookie: cookie_header(first))

          expect(binding_cookies(second)).to be_empty
        end
      end
    end
  end
end
