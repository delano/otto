# spec/otto/security/csp_reporting_frozen_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tempfile'

# Otto skips its lazy configuration freeze under RSpec (see Otto#call), so the
# normal request path never drives the report receiver against a genuinely
# frozen config — the exact production condition. This spec closes that blind
# spot by freezing a single instance explicitly and proving the report path
# still works: the frozen Config's callback stays callable and dispatch fires.
RSpec.describe 'Otto CSP violation reporting against a frozen configuration' do
  include Rack::Test::Methods

  class FrozenCspApp
    def initialize(req, res)
      @res = res
    end

    def index
      @res.write('ok')
    end
  end

  let(:routes_file) do
    file = Tempfile.new(['frozen_csp_routes', '.txt'])
    file.write("GET / FrozenCspApp#index\n")
    file.flush
    file
  end

  let(:violations) { [] }

  let(:otto) do
    instance = Otto.new(routes_file.path)
    instance.enable_csrf_protection!
    instance.enable_csp_reporting!('/_/csp-report') { |report| violations << report }
    # Freeze the whole instance the way the first real request would in
    # production (RSpec normally skips this). freeze_configuration! is private.
    instance.send(:freeze_configuration!)
    instance
  end

  def app
    otto
  end

  after { routes_file.close! }

  it 'freezes the security config' do
    expect(otto.security_config.frozen?).to be true
  end

  it 'still receives a tokenless report POST, dispatches it, and answers 204' do
    body = { 'csp-report' => { 'violated-directive' => 'img-src' } }.to_json
    post '/_/csp-report', body, 'CONTENT_TYPE' => 'application/csp-report'

    expect(last_response.status).to eq(204)
    expect(violations.length).to eq(1)
    expect(violations.first.violated_directive).to eq('img-src')
  end
end
