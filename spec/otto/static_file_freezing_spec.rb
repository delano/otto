# spec/otto/static_file_freezing_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Regression coverage for issue #185: lazy static-file discovery
# (Core::Router#handle_request / Core::FileSafety#add_static_path) writes into
# routes_static[:GET] at request time, but freeze_configuration! runs before
# any request is served. Under RSpec that freeze is skipped for #call, so
# these specs freeze explicitly to exercise the path the way production does
# (lazy freeze on the first real request).
RSpec.describe Otto, 'static file serving after configuration freeze' do
  subject(:otto) { described_class.new(nil, { public: '/tmp/test_static_freezing' }) }

  before do
    Dir.mkdir('/tmp/test_static_freezing') unless Dir.exist?('/tmp/test_static_freezing')
    File.write('/tmp/test_static_freezing/asset.txt', 'asset content')
  end

  after do
    FileUtils.rm_rf('/tmp/test_static_freezing') if Dir.exist?('/tmp/test_static_freezing')
  end

  it 'serves an uncached static file without raising FrozenError' do
    otto.freeze_configuration!
    expect(otto.frozen_configuration?).to be true
    expect(otto.routes_static[:GET].key?('/')).to be false

    status, = otto.call(Rack::MockRequest.env_for('/asset.txt'))

    expect(status).to eq(200)
  end

  # The cache key is the canonical *directory* of the served file (issue
  # #257), so a file in the public root is cached under '/'.
  it 'caches the base path in routes_static[:GET] for subsequent requests' do
    otto.freeze_configuration!

    otto.call(Rack::MockRequest.env_for('/asset.txt'))

    expect(otto.routes_static[:GET].key?('/')).to be true
  end

  it 'does not deep-freeze routes_static, so the request-time cache write succeeds' do
    otto.freeze_configuration!

    expect { otto.routes_static[:GET]['/manual.txt'] = '/manual.txt' }.not_to raise_error
  end

  it 'shallow-freezes the outer routes_static hash so its verb-key structure cannot change' do
    otto.freeze_configuration!

    expect(otto.routes_static).to be_frozen
    expect { otto.routes_static[:DELETE] = {} }.to raise_error(FrozenError)
  end

  it 'survives concurrent requests for distinct uncached files without error or lost writes' do
    file_count = 50
    file_count.times { |i| File.write("/tmp/test_static_freezing/concurrent_#{i}.txt", "content #{i}") }
    otto.freeze_configuration!

    errors = Queue.new
    threads = Array.new(file_count) do |i|
      Thread.new do
        status, = otto.call(Rack::MockRequest.env_for("/concurrent_#{i}.txt"))
        errors << "unexpected status #{status} for concurrent_#{i}.txt" unless status == 200
      rescue StandardError => e
        errors << "#{e.class}: #{e.message}"
      end
    end
    threads.each(&:join)

    expect(errors).to be_empty
    expect(otto.routes_static[:GET].key?('/')).to be true
  end
end
