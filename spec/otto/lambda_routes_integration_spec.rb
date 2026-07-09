# spec/otto/lambda_routes_integration_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# End-to-end acceptance coverage for issue #41 (Lambda / Inline Route Handlers).
#
# Every example here drives a *real* request through a *real* Otto instance via
# otto.call(mock_rack_env(...)) — the full middleware + router + factory +
# LambdaHandler + response/auth pipeline. This is the executable acceptance
# spec for the feature as a whole: dispatch, response types, route options
# (csrf / auth / role / custom params), and — the point of the feature —
# security: an unregistered handler yields a clear error and executes NO code,
# and a handler name that looks like Ruby source is treated as a plain (absent)
# registry key, never resolved as a constant and never eval'd.
#
# House style follows spec/otto/response_integration_spec.rb: build an Otto,
# call it with a mock env, and assert on the [status, headers, body] triple.
# Per the test plan we NEVER stub otto.config / otto.option — always a real
# Otto built with `lambda_handlers:` so the frozen registry is exercised.
RSpec.describe 'Otto lambda routes end-to-end (issue #41)' do
  # Build a real Otto from one or more route lines plus a lambda registry.
  # @param routes [Array<String>] route-file lines
  # @param handlers [Hash] the lambda_handlers registry
  # @param opts [Hash] extra Otto options (csrf_protection, auth_strategies, ...)
  def build_otto(routes, handlers, **opts)
    routes_file = create_test_routes_file('test_routes_lambda_e2e.txt', routes)
    Otto.new(routes_file, { lambda_handlers: handlers }.merge(opts))
  end

  describe 'D1: request dispatch (GET and POST)' do
    it 'dispatches a GET lambda route and renders its Hash return as JSON' do
      otto = build_otto(
        ['GET /ping &health_check response=json'],
        { 'health_check' => ->(_req, _res, _extra) { { status: 'ok' } } }
      )

      status, headers, body = otto.call(mock_rack_env(method: 'GET', path: '/ping'))

      expect(status).to eq(200)
      expect(headers['Content-Type']).to eq('application/json')
      expect(JSON.parse(body.join)).to eq('status' => 'ok')
    end

    it 'dispatches a POST lambda route and can read request params' do
      otto = build_otto(
        ['POST /submit &submit response=json'],
        { 'submit' => ->(req, _res, _extra) { { name: req.params['name'] } } }
      )

      env = mock_rack_env(method: 'POST', path: '/submit', params: { 'name' => 'x' })
      status, _headers, body = otto.call(env)

      expect(status).to eq(200)
      expect(JSON.parse(body.join)).to eq('name' => 'x')
    end
  end

  describe 'D2: response types (AC#5), one route each, driven through otto.call' do
    it 'json: a Hash return becomes a JSON body with capitalized Content-Type' do
      otto = build_otto(
        ['GET /j &jh response=json'],
        { 'jh' => ->(_req, _res, _extra) { { ok: true } } }
      )

      status, headers, body = otto.call(mock_rack_env(path: '/j'))

      expect(status).to eq(200)
      expect(headers['Content-Type']).to eq('application/json')
      expect(JSON.parse(body.join)).to eq('ok' => true)
    end

    it 'view: a String return becomes an HTML body (text/html)' do
      otto = build_otto(
        ['GET /v &vh response=view'],
        { 'vh' => ->(_req, _res, _extra) { '<h1>Hi</h1>' } }
      )

      status, headers, body = otto.call(mock_rack_env(path: '/v'))

      expect(status).to eq(200)
      expect(headers['Content-Type']).to eq('text/html')
      expect(body.join).to eq('<h1>Hi</h1>')
    end

    it 'redirect: a String return becomes a 302 with a Location header' do
      otto = build_otto(
        ['GET /r &rh response=redirect'],
        { 'rh' => ->(_req, _res, _extra) { '/next' } }
      )

      status, headers, _body = otto.call(mock_rack_env(path: '/r'))

      expect(status).to eq(302)
      expect(headers['Location']).to eq('/next')
    end

    it 'auto: a Hash return is auto-detected as JSON' do
      otto = build_otto(
        ['GET /a &ah response=auto'],
        { 'ah' => ->(_req, _res, _extra) { { ok: true } } }
      )

      status, headers, body = otto.call(mock_rack_env(path: '/a'))

      expect(status).to eq(200)
      expect(headers['Content-Type']).to eq('application/json')
      expect(JSON.parse(body.join)).to eq('ok' => true)
    end

    it 'default: the written body is served and the return value is ignored' do
      otto = build_otto(
        ['GET /d &dh'],
        # Writes to res AND returns a Hash: under the default response type the
        # return value must be ignored and only what was written is served.
        { 'dh' => ->(_req, res, _extra) { res.write('written'); { ignored: true } } }
      )

      status, _headers, body = otto.call(mock_rack_env(path: '/d'))

      expect(status).to eq(200)
      expect(body.join).to eq('written')
    end
  end

  describe 'D3: route options — custom params and csrf=exempt (AC#6)' do
    it 'delivers a captured path param to the lambda (req.params and extra_params)' do
      seen_extra = nil
      otto = build_otto(
        ['GET /users/:id &show_user response=json'],
        { 'show_user' => lambda { |req, _res, extra|
          seen_extra = extra
          { from_params: req.params['id'], from_extra: extra['id'] }
        } }
      )

      status, _headers, body = otto.call(mock_rack_env(path: '/users/42'))

      expect(status).to eq(200)
      # AC#4/AC#6: the capture reaches the lambda both via req.params and as the
      # 3rd (extra_params) argument.
      expect(JSON.parse(body.join)).to eq('from_params' => '42', 'from_extra' => '42')
      expect(seen_extra).to include('id' => '42')
    end

    context 'csrf=exempt on a POST lambda route (parse + expose only)' do
      # The route file parses csrf=exempt into the route definition and exposes
      # it, but CSRFMiddleware does not enforce per-route exemption for ANY
      # handler kind (it ignores route options). So we assert two honest things:
      #   1. the option is parsed and exposed on the route definition, and
      #   2. the exempt lambda route behaves IDENTICALLY to an equivalent
      #      controller route under the same csrf configuration.
      # We deliberately do NOT assert that the exemption bypasses CSRF, because
      # the middleware does not honor it (see issue notes).
      it 'parses and exposes csrf=exempt on the route definition' do
        rd = Otto::RouteDefinition.new('POST', '/webhook', '&hook csrf=exempt response=json')
        expect(rd.kind).to eq(:lambda)
        expect(rd.option(:csrf)).to eq('exempt')
        expect(rd.csrf_exempt?).to be(true)
      end

      it 'behaves identically to a controller route under csrf_protection' do
        lambda_otto = build_otto(
          ['POST /webhook &hook csrf=exempt response=json'],
          { 'hook' => ->(_req, _res, _extra) { { ok: true } } },
          csrf_protection: true
        )

        controller_routes = create_test_routes_file(
          'test_routes_lambda_ctrl.txt',
          ['POST /webhook TestApp.create csrf=exempt response=json']
        )
        controller_otto = Otto.new(controller_routes, csrf_protection: true)

        lambda_status, = lambda_otto.call(mock_rack_env(method: 'POST', path: '/webhook'))
        controller_status, = controller_otto.call(mock_rack_env(method: 'POST', path: '/webhook'))

        # Parity: whatever CSRFMiddleware does to a tokenless POST, it does the
        # same to the lambda route and the controller route.
        expect(lambda_status).to eq(controller_status)
      end
    end
  end

  describe 'D4: auth / role protected lambda routes (AC#6)' do
    # A minimal role-aware session strategy, mirroring the pattern used in
    # spec/otto/security/route_auth_wrapper_spec.rb.
    let(:role_strategy) do
      Class.new do
        def authenticate(env, _requirement)
          session = env['rack.session']
          unless session && session['user_id']
            return Otto::Security::Authentication::AuthFailure.new(
              failure_reason: 'No session',
              auth_method: 'session'
            )
          end

          Otto::Security::Authentication::StrategyResult.new(
            user: { id: session['user_id'], roles: session['user_roles'] || [] },
            session: session,
            auth_method: 'session',
            metadata: {},
            strategy_name: 'session'
          )
        end
      end.new
    end

    def build_auth_otto(route_line, handler_key)
      build_otto(
        [route_line],
        { handler_key => ->(_req, _res, _extra) { { admin: true } } },
        # Register the same role-aware strategy under both requirement names so
        # `auth=authenticated` and `auth=session` routes both resolve.
        auth_strategies: { 'authenticated' => role_strategy, 'session' => role_strategy },
        default_auth_strategy: 'session'
      )
    end

    def json_env(path, session: nil)
      env = mock_rack_env(method: 'GET', path: path, headers: { 'Accept' => 'application/json' })
      env['rack.session'] = session if session
      env
    end

    context 'auth=authenticated' do
      let(:otto) { build_auth_otto('GET /admin &admin_panel auth=authenticated response=json', 'admin_panel') }

      it 'runs the lambda and returns 200 for an authenticated session' do
        status, _headers, body = otto.call(json_env('/admin', session: { 'user_id' => 1 }))

        expect(status).to eq(200)
        expect(JSON.parse(body.join)).to eq('admin' => true)
      end

      it 'returns 401 and does NOT run the lambda for an empty session' do
        status, headers, body = otto.call(json_env('/admin', session: {}))

        expect(status).to eq(401)
        expect(headers['content-type']).to eq('application/json')
        # The body is the auth error, not the lambda's {admin: true} payload.
        parsed = JSON.parse(body.join)
        expect(parsed).not_to include('admin' => true)
        expect(parsed['error']).to match(/Authentication Required/i)
      end
    end

    context 'auth=session role=admin' do
      let(:otto) { build_auth_otto('GET /admin &admin_panel auth=session role=admin response=json', 'admin_panel') }

      it 'returns 403 for the wrong role and does NOT run the lambda' do
        status, headers, body = otto.call(
          json_env('/admin', session: { 'user_id' => 2, 'user_roles' => ['user'] })
        )

        expect(status).to eq(403)
        expect(headers['content-type']).to eq('application/json')
        parsed = JSON.parse(body.join)
        expect(parsed).not_to include('admin' => true)
        expect(parsed['error']).to match(/Forbidden/i)
      end

      it 'runs the lambda and returns 200 for the correct role' do
        status, _headers, body = otto.call(
          json_env('/admin', session: { 'user_id' => 3, 'user_roles' => ['admin'] })
        )

        expect(status).to eq(200)
        expect(JSON.parse(body.join)).to eq('admin' => true)
      end
    end
  end

  describe 'D5: security — no eval, no dynamic code execution (AC#7, AC#8)' do
    it 'an UNregistered handler yields a generic 500 JSON error (details only logged)' do
      otto = build_otto(['GET /danger &danger_handler response=json'], {})

      status, headers, body = otto.call(
        mock_rack_env(method: 'GET', path: '/danger', headers: { 'Accept' => 'application/json' })
      )

      expect(status).to eq(500)
      expect(headers['content-type']).to eq('application/json')
      parsed = JSON.parse(body.join)
      # Generic message — the specific "not registered" detail is logged, not leaked.
      expect(parsed['error']).to eq('Internal Server Error')
    end

    it 'a source-looking handler name is treated as an absent key and executes nothing' do
      executed = [] # closure-local canary (order.random-safe; no globals)
      otto = build_otto(
        ["GET /x &system('boom') response=json"],
        # The ONLY registered proc; its key is unrelated to the route's token.
        { 'safe' => ->(_req, _res, _extra) { executed << :ran; { ok: true } } }
      )

      # Nothing should ever shell out: the token is a registry key, never eval'd.
      expect(Kernel).not_to receive(:system)

      status, = otto.call(
        mock_rack_env(method: 'GET', path: '/x', headers: { 'Accept' => 'application/json' })
      )

      expect(status).to eq(500)
      expect(executed).to be_empty
    end

    it 'a dotted handler name is the whole (absent) key — never sent to constant resolution' do
      executed = []
      otto = build_otto(
        ['GET /y &Kernel.system response=json'],
        { 'safe' => ->(_req, _res, _extra) { executed << :ran; { ok: true } } }
      )

      status, = otto.call(
        mock_rack_env(method: 'GET', path: '/y', headers: { 'Accept' => 'application/json' })
      )

      # "Kernel.system" is the (missing) registry key in full; it is not split,
      # not resolved as a constant, and no code runs.
      expect(status).to eq(500)
      expect(executed).to be_empty
    end
  end
end
