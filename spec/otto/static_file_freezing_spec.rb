# spec/otto/static_file_freezing_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'static file serving after configuration freeze' do
  let(:public_dir) { Dir.mktmpdir('otto_static_freezing') }

  after do
    FileUtils.remove_entry(public_dir) if File.exist?(public_dir)
  end

  it 'serves a static file after configuration is frozen' do
    File.write(File.join(public_dir, 'asset.txt'), 'asset content')
    app = described_class.new(nil, { public: public_dir })
    app.freeze_configuration!

    status, _headers, body = app.call(Rack::MockRequest.env_for('/asset.txt'))

    expect(app.frozen_configuration?).to be true
    expect(status).to eq(200)
    expect(body.to_enum(:each).to_a.join).to eq('asset content')
  end

  it 'serves concurrent static requests after configuration is frozen' do
    file_count = 50
    file_count.times { |i| File.write(File.join(public_dir, "concurrent_#{i}.txt"), "content #{i}") }
    app = described_class.new(nil, { public: public_dir })
    app.freeze_configuration!

    errors = Queue.new
    threads = Array.new(file_count) do |i|
      Thread.new do
        status, _headers, body = app.call(Rack::MockRequest.env_for("/concurrent_#{i}.txt"))
        content = body.to_enum(:each).to_a.join
        errors << "unexpected response #{status}: #{content}" unless status == 200 && content == "content #{i}"
      rescue StandardError => e
        errors << "#{e.class}: #{e.message}"
      end
    end
    threads.each(&:join)

    expect(errors).to be_empty
  end

  it 'keeps literal routes ahead of static files regardless of request history' do
    assets_dir = File.join(public_dir, 'assets')
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, 'collision.txt'), 'static collision')
    File.write(File.join(assets_dir, 'sibling.txt'), 'static sibling')
    routes_file = create_test_routes_file(
      'static_literal_precedence.txt',
      ['GET /assets/collision.txt TestApp.index']
    )
    app = described_class.new(routes_file, { public: public_dir })
    app.freeze_configuration!

    first = app.call(Rack::MockRequest.env_for('/assets/collision.txt'))
    sibling = app.call(Rack::MockRequest.env_for('/assets/sibling.txt'))
    second = app.call(Rack::MockRequest.env_for('/assets/collision.txt'))

    expect(first[0]).to eq(200)
    expect(first[2].to_enum(:each).to_a.join).to eq('Hello World')
    expect(sibling[0]).to eq(200)
    expect(sibling[2].to_enum(:each).to_a.join).to eq('static sibling')
    expect(second[0]).to eq(200)
    expect(second[2].to_enum(:each).to_a.join).to eq('Hello World')
  end
end
