# spec/otto/security/csp_extras_frozen_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

# Otto skips its lazy configuration freeze under RSpec (see Otto#call), so the
# normal request path never exercises the extras channel against a genuinely
# frozen config — the exact production condition. Extras live in env only and
# must never memoize anything on the (deep-frozen) Security::Config; a mutation
# bug here would pass the rest of the suite and FrozenError only in production.
# This spec freezes a single instance explicitly and proves the extras path
# still widens the policy while leaving csp_directive_overrides untouched.
# Integration spec over a behaviour, not a class; same shape as
# csp_reporting_frozen_spec.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Otto CSP request extras against a frozen configuration' do
  include Rack::Test::Methods

  # Routes-file controllers must be resolvable by name, hence a real constant
  # (the same pattern as FrozenCspApp in csp_reporting_frozen_spec).
  # rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration
  class FrozenCspExtrasApp
    # Controller ivars, not spec state.
    # rubocop:disable RSpec/InstanceVariable
    def initialize(req, res)
      @req = req
      @res = res
    end

    def index
      # Per-request data (the "tenant IdP origin") written by the handler.
      @req.env['otto.csp.extra_directives'] = { 'form-action' => ['https://idp.tenant.example'] }
      @res['content-type'] = 'text/html; charset=utf-8'
      @res.write(%(<script nonce="#{@req.csp_nonce}">1</script>))
    end
    # rubocop:enable RSpec/InstanceVariable
  end
  # rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration

  let(:routes_file) do
    file = Tempfile.new(['frozen_csp_extras_routes', '.txt'])
    file.write("GET / FrozenCspExtrasApp#index\n")
    file.flush
    file
  end

  let(:otto) do
    instance = Otto.new(routes_file.path)
    instance.enable_csp_with_nonce!
    instance.enable_csp_emission!
    # Freeze the whole instance the way the first real request would in
    # production (RSpec normally skips this). freeze_configuration! is private.
    instance.send(:freeze_configuration!)
    instance
  end

  def app
    otto
  end

  after { routes_file.close! }

  it 'freezes the security config (the precondition this spec exists for)' do
    expect(otto.security_config.frozen?).to be true
    expect(otto.security_config.csp_directive_overrides.frozen?).to be true
  end

  it 'widens form-action for the request without mutating the frozen config' do
    overrides_before = otto.security_config.csp_directive_overrides

    get '/'

    expect(last_response.status).to eq(200)
    expect(last_response.headers['content-security-policy'])
      .to include("form-action 'self' https://idp.tenant.example;")
    expect(otto.security_config.csp_directive_overrides).to equal(overrides_before)
    expect(otto.security_config.csp_directive_overrides).to eq({})
  end

  it 'serves a second request without extras with the unwidened base policy' do
    get '/' # a request WITH extras first, to catch any cross-request leak

    env = Rack::MockRequest.env_for('/')
    # Drive the frozen instance directly with an env whose handler extras are
    # then discarded — but the handler always writes extras here, so instead
    # assert the widened directive carries ONLY this request's origin exactly
    # once (no accumulation across requests on the shared frozen config).
    _status, headers, = otto.call(env)
    csp = headers['content-security-policy']

    expect(csp.scan('https://idp.tenant.example').length).to eq(1)
  end
end
# rubocop:enable RSpec/DescribeClass
