# spec/otto/utils_routing_path_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Otto::Utils.routing_path is only useful if it is what the router matches. A
# guard in front of the router decides on it; these specs send crafted paths
# through a real Otto app (and through Rack::URLMap for the mounted case) and
# check that the guard's comparison and the router's dispatch agree on every
# one of them.
RSpec.describe Otto::Utils, '.routing_path' do
  let(:otto) do
    create_minimal_otto([
                          'GET / TestApp.index',
                          'GET /colonel TestApp.custom_headers',
                          'GET /show/:id TestApp.show',
                        ])
  end

  # The guard's own view of the protected route, normalized the same way.
  let(:guarded) { described_class.normalize_path('/colonel') }

  # What a guard sitting directly in front of the router sees, and the
  # response. With +mount+, Rack::URLMap mounts guard and app at that prefix.
  def through_guard(path_info, mount: nil)
    seen  = {}
    guard = lambda do |env|
      seen[:path]    = described_class.routing_path(env)
      seen[:mounted] = described_class.routing_path(env, include_mount: true)
      otto.call(env)
    end
    app = mount ? Rack::URLMap.new(mount => guard) : guard

    # Set PATH_INFO directly: env_for parses its argument as a URI and
    # rejects some of the crafted paths before they reach Rack.
    env = Rack::MockRequest.env_for('/')
    env['PATH_INFO'] = path_info
    [seen, app.call(env)]
  end

  def colonel_dispatched?(response)
    response[0] == 200 && response[2].join == 'Custom headers'
  end

  {
    '/colonel' => true,
    '/colonel/' => true,
    '/%63olonel' => true,
    '/%63olonel/' => true,
    '/colonel%2F' => true,
    '/colonel%FF' => true,
    "/colonel\xFF" => true,
    '/%2563olonel' => false,
    '/Colonel' => false,
    '//colonel' => false,
    '/colonel/x' => false,
    '/colonelx' => false,
  }.each do |path_info, expected|
    it "agrees with the router on #{path_info.inspect}" do
      seen, response = through_guard(path_info)

      expect(seen[:path] == guarded).to eq(expected)
      expect(colonel_dispatched?(response)).to eq(expected)
    end
  end

  context 'when the app is mounted under a sub-path with Rack::URLMap' do
    it 'sees the mount-relative path the router dispatches, and the mounted one on request' do
      seen, response = through_guard('/api/%63olonel', mount: '/api')

      expect(colonel_dispatched?(response)).to be(true)
      expect(seen[:path]).to eq('/colonel')
      expect(seen[:mounted]).to eq('/api/colonel')
    end

    it 'gives the same mount-relative path in two apps and distinct mounted paths' do
      v1   = create_minimal_otto(['GET /colonel TestApp.index'])
      seen = {}
      probe = lambda do |name, app|
        lambda do |env|
          seen[name] = [described_class.routing_path(env), described_class.routing_path(env, include_mount: true)]
          app.call(env)
        end
      end
      map = Rack::URLMap.new('/api/v1' => probe.call(:v1, v1), '/api/v2' => probe.call(:v2, otto))

      v1_response = map.call(Rack::MockRequest.env_for('/api/v1/colonel'))
      v2_response = map.call(Rack::MockRequest.env_for('/api/v2/colonel'))

      expect(v1_response[2].join).to eq('Hello World')
      expect(colonel_dispatched?(v2_response)).to be(true)
      expect(seen[:v1]).to eq(['/colonel', '/api/v1/colonel'])
      expect(seen[:v2]).to eq(['/colonel', '/api/v2/colonel'])
    end
  end
end
