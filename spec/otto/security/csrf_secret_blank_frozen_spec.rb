# spec/otto/security/csrf_secret_blank_frozen_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

# csrf_secret= turns nil and blank secrets into a generated secret (see
# config_csrf_secret_blank_spec). Otto skips its lazy configuration freeze
# under RSpec (see Otto#call), so this spec freezes an app explicitly and
# checks that HTML pages still get a token signed with the generated secret
# and that a token forged with the blank value as the HMAC key is rejected.
# Integration spec over a behaviour, not a class; same shape as
# csrf_generated_secret_frozen_spec.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe 'A blank or nil CSRF secret in a frozen Otto app' do
  include Rack::Test::Methods

  # Routes-file controllers must be resolvable by name, hence a real constant.
  # rubocop:disable-next Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
  class BlankCsrfSecretFrozenApp
    # Controller ivars, not spec state.
    # rubocop:disable RSpec/InstanceVariable
    def initialize(_req, res)
      @res = res
    end

    def index
      @res['content-type'] = 'text/html; charset=utf-8'
      @res.write('<html><head><title>t</title></head><body>ok</body></html>')
    end

    def create
      @res['content-type'] = 'text/plain'
      @res.write('created')
    end
    # rubocop:enable RSpec/InstanceVariable
  end

  let(:routes_file) do
    file = Tempfile.new(['csrf_secret_blank_frozen_routes', '.txt'])
    file.write("GET / BlankCsrfSecretFrozenApp#index\n")
    file.write("POST / BlankCsrfSecretFrozenApp#create\n")
    file.flush
    file
  end

  let(:otto) do
    instance = Otto.new(routes_file.path, csrf_protection: true)
    instance.security_config.csrf_secret = secret
    # Freeze the way the first real request would outside the test suite.
    # freeze_configuration! is private.
    instance.send(:freeze_configuration!)
    instance
  end

  around do |example|
    original_env = ENV.fetch('RACK_ENV', nil)
    # Outside production a generated secret is allowed and only warned about.
    ENV['RACK_ENV'] = 'development'
    example.run
  ensure
    ENV['RACK_ENV'] = original_env
  end

  before do
    allow(Otto.logger).to receive(:warn)
    set_cookie '_otto_session=sess1'
  end

  after { routes_file.close! }

  def app
    otto
  end

  def forged_token(key)
    token_part = 'deadbeef'
    "#{token_part}:#{OpenSSL::HMAC.hexdigest('SHA256', key, "sess1:#{token_part}")}"
  end

  { 'an empty string' => '', 'nil' => nil }.each do |label, value|
    context "with #{label}" do
      let(:secret) { value }

      it 'serves HTML pages with a token that verifies' do
        get '/'

        expect(last_response.status).to eq(200)
        token = last_response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        expect(token).not_to be_nil

        post '/', '_csrf_token' => token
        expect(last_response.status).to eq(200)
      end

      it 'rejects a token forged with the blank value as the HMAC key' do
        post '/', '_csrf_token' => forged_token(value.to_s)

        expect(last_response.status).to eq(403)
      end
    end
  end
end
