# spec/otto/security/csrf_malformed_token_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# A presented CSRF token is whatever the client sends. Rack parses
# _csrf_token[]=v into an Array and _csrf_token[k]=v into a Hash, and decodes
# percent escapes into a UTF-8 String that may hold multibyte characters or
# invalid bytes. The Rack SPEC asks servers to pass header values that hold
# non-ASCII characters as ASCII-8BIT. Each of these must fail the CSRF check
# with a 403. If the check raises, Otto answers 500 instead.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'CSRF enforcement with a malformed token' do
  include OttoTestHelpers

  let(:otto) do
    handlers = {
      'login' => lambda do |_req, res, _extra|
        res['content-type'] = 'text/plain'
        res.write('logged in')
      end,
    }
    routes = create_test_routes_file('test_routes_csrf_malformed_token.txt', ['POST /login &login'])
    Otto.new(routes, lambda_handlers: handlers, csrf_protection: true).tap do |app|
      app.security_config.csrf_secret = 'm' * 64
    end
  end

  let(:binding_id) { 'binding123' }
  let(:token_part) { otto.security_config.generate_csrf_token(binding_id).split(':', 2).first }

  # POSTs a form body to /login with the binding in the plain HTTP binding
  # cookie, and returns the status.
  def post_login(form_body, binding: binding_id, headers: {})
    env = Rack::MockRequest.env_for('http://example.org/login',
                                    method: 'POST',
                                    input: form_body,
                                    'CONTENT_TYPE' => 'application/x-www-form-urlencoded')
    env['HTTP_COOKIE'] = "_otto_session=#{Rack::Utils.escape(binding)}"
    env.merge!(headers)
    otto.call(env).first
  end

  it 'accepts a valid token, so the 403s below come from the token' do
    token = otto.security_config.generate_csrf_token(binding_id)

    expect(post_login("_csrf_token=#{Rack::Utils.escape(token)}")).to eq(200)
  end

  # 64 characters, the length of a hex HMAC-SHA256 signature, but 128 bytes.
  it 'refuses a signature of 64 multibyte characters with 403' do
    signature = Rack::Utils.escape('é' * 64)

    expect(post_login("_csrf_token=#{token_part}%3A#{signature}")).to eq(403)
  end

  it 'refuses a token parameter that Rack parses into an Array with 403' do
    token = otto.security_config.generate_csrf_token(binding_id)

    expect(post_login("_csrf_token[]=#{Rack::Utils.escape(token)}")).to eq(403)
  end

  it 'refuses a token parameter that Rack parses into a Hash with 403' do
    token = otto.security_config.generate_csrf_token(binding_id)

    expect(post_login("_csrf_token[k]=#{Rack::Utils.escape(token)}")).to eq(403)
  end

  it 'refuses a token with invalid UTF-8 bytes with 403' do
    expect(post_login("_csrf_token=#{token_part}%3A#{'%FF' * 64}")).to eq(403)
    expect(post_login("_csrf_token=#{'%FF' * 8}")).to eq(403)
  end

  # Rack decodes the cookie into a UTF-8 binding, and the token's first part
  # goes into the HMAC input next to it.
  it 'refuses an ASCII-8BIT header token with non-ASCII bytes against a non-ASCII binding with 403' do
    header = { 'HTTP_X_CSRF_TOKEN' => "#{'é' * 32}:#{'0' * 64}".b }

    expect(post_login('', binding: 'é-binding', headers: header)).to eq(403)
  end

  it 'refuses a UTF-8 header token of 64 multibyte characters with 403' do
    header = { 'HTTP_X_CSRF_TOKEN' => "#{token_part}:#{'é' * 64}" }

    expect(post_login('', headers: header)).to eq(403)
  end
end
