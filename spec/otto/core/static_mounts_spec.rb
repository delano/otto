# spec/otto/core/static_mounts_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# Explicit static-file registration (issue #267): Otto#mount_static binds a
# URL prefix to one canonical directory, validated at registration and served
# under the same containment policy as the implicit public directory.
RSpec.describe Otto::Core::StaticMounts do
  let(:base) { Dir.mktmpdir('otto_static_mounts') }
  let(:assets_dir) { File.join(base, 'assets') }
  let(:vendor_dir) { File.join(base, 'vendor') }
  let(:public_dir) { File.join(base, 'public') }

  before do
    FileUtils.mkdir_p(File.join(assets_dir, 'js'))
    FileUtils.mkdir_p(vendor_dir)
    FileUtils.mkdir_p(File.join(public_dir, 'assets'))
    File.write(File.join(assets_dir, 'app.css'), 'assets app.css')
    File.write(File.join(assets_dir, 'js', 'app.js'), 'assets app.js')
    File.write(File.join(vendor_dir, 'lib.js'), 'vendor lib.js')
    File.write(File.join(public_dir, 'index.html'), 'public index')
    File.write(File.join(public_dir, 'assets', 'app.css'), 'public app.css')
    # A file beside the mount roots that no registration authorizes.
    File.write(File.join(base, 'secret.txt'), 'secret')
  end

  after do
    FileUtils.rm_rf(base)
  end

  def get(app, path, method: 'GET')
    status, headers, body = app.call(Rack::MockRequest.env_for(path, method: method))
    [status, headers, body.to_enum(:each).to_a.join]
  end

  describe '#mount_static' do
    it 'serves files under the prefix from the mount root' do
      app = Otto.new
      app.mount_static('/assets', root: assets_dir)

      expect(get(app, '/assets/app.css')).to include(200, 'assets app.css')
      expect(get(app, '/assets/js/app.js')).to include(200, 'assets app.js')
    end

    it 'maps the prefix onto the root rather than exposing the root at its own path' do
      app = Otto.new
      app.mount_static('/static', root: assets_dir)

      expect(get(app, '/static/app.css').first).to eq(200)
      expect(get(app, '/assets/app.css').first).to eq(404)
      expect(get(app, '/app.css').first).to eq(404)
    end

    it 'mounts a root directory at the top level with "/"' do
      app = Otto.new
      app.mount_static('/', root: assets_dir)

      expect(get(app, '/app.css')).to include(200, 'assets app.css')
      expect(get(app, '/js/app.js')).to include(200, 'assets app.js')
    end

    it 'ignores a trailing slash on the prefix' do
      app = Otto.new
      app.mount_static('/assets/', root: assets_dir)

      expect(app.static_mounts.map(&:prefix)).to eq(['/assets'])
      expect(get(app, '/assets/app.css').first).to eq(200)
    end

    it 'canonicalizes the root at registration' do
      link = File.join(base, 'assets-link')
      File.symlink(assets_dir, link)
      app = Otto.new
      mount = app.mount_static('/assets', root: link)

      expect(mount.root).to eq(File.realpath(assets_dir))
      expect(get(app, '/assets/app.css').first).to eq(200)
    end

    it 'normalizes dot segments in the root at registration' do
      app = Otto.new
      app.mount_static('/assets', root: File.join(assets_dir, 'js', '..', '.'))

      expect(app.static_mounts.first.root).to eq(File.realpath(assets_dir))
    end

    it 'returns the registered mount and exposes a frozen, longest-prefix-first table' do
      app = Otto.new
      app.mount_static('/assets', root: assets_dir)
      mount = app.mount_static('/assets/vendor', root: vendor_dir)

      expect(mount).to be_frozen
      expect(app.static_mounts).to be_frozen
      expect(app.static_mounts.map(&:prefix)).to eq(['/assets/vendor', '/assets'])
    end

    it 'sets a content type for served files' do
      app = Otto.new
      app.mount_static('/assets', root: assets_dir)

      _status, headers, _body = get(app, '/assets/js/app.js')
      # Rack::Mime has reported .js as both application/javascript and
      # text/javascript across releases; either is a JavaScript type.
      expect(headers['content-type']).to match(%r{\A(text|application)/javascript})
    end
  end

  describe 'file resolution' do
    let(:app) do
      Otto.new.tap { |otto| otto.mount_static('/assets', root: assets_dir) }
    end

    it 'does not serve the prefix itself' do
      expect(get(app, '/assets').first).to eq(404)
      expect(get(app, '/assets/').first).to eq(404)
    end

    it 'does not serve directories under the prefix' do
      expect(get(app, '/assets/js').first).to eq(404)
    end

    it 'does not match a longer path segment that merely starts with the prefix' do
      FileUtils.mkdir_p(File.join(base, 'assets2'))
      File.write(File.join(base, 'assets2', 'x.txt'), 'x')

      expect(get(app, '/assets2/x.txt').first).to eq(404)
    end

    it 'serves only GET requests' do
      expect(get(app, '/assets/app.css', method: 'POST').first).to eq(404)
      expect(get(app, '/assets/app.css', method: 'PUT').first).to eq(404)
    end

    it 'falls through when the file is missing' do
      expect(get(app, '/assets/missing.css')).to include(404)
    end

    it 'treats a leading slash on the relative path as root-relative' do
      # Dispatch always hands resolve_file_under a leading-slash path. Ruby's
      # File.join keeps every component (unlike Python's os.path.join), so the
      # root is never discarded; pin that so the join is not "fixed" later.
      mount = app.static_mounts.first
      resolved = app.resolve_file_under(mount.root, '/js/app.js')

      expect(resolved).to have_attributes(root: mount.root, relative: 'js/app.js')
      expect(app.resolve_file_under(mount.root, '//js/app.js')).to have_attributes(relative: 'js/app.js')
      expect(app.resolve_file_under(mount.root, '/../secret.txt')).to be_nil
    end
  end

  describe 'containment' do
    let(:app) do
      Otto.new.tap { |otto| otto.mount_static('/assets', root: assets_dir) }
    end

    it 'rejects path traversal out of the mount root' do
      expect(get(app, '/assets/../secret.txt').first).to eq(404)
      expect(get(app, '/assets/js/../../secret.txt').first).to eq(404)
      expect(get(app, '/assets/%2e%2e/secret.txt').first).to eq(404)
      expect(get(app, '/assets/js/%2e%2e/%2e%2e/secret.txt').first).to eq(404)
    end

    it 'rejects a NUL byte in the request path' do
      expect(get(app, '/assets/app.css%00').first).to eq(404)
    end

    it 'rejects a symlink that escapes the mount root' do
      File.symlink(File.join(base, 'secret.txt'), File.join(assets_dir, 'leak.txt'))
      File.symlink(vendor_dir, File.join(assets_dir, 'leakdir'))

      expect(get(app, '/assets/leak.txt').first).to eq(404)
      expect(get(app, '/assets/leakdir/lib.js').first).to eq(404)
    end

    it 'serves a symlink whose target stays inside the mount root' do
      File.symlink(File.join(assets_dir, 'app.css'), File.join(assets_dir, 'alias.css'))

      expect(get(app, '/assets/alias.css')).to include(200, 'assets app.css')
    end

    it 'never authorizes files beside the mount root' do
      # The parent of the mount root contains secret.txt and vendor/; neither
      # is reachable through the registration.
      expect(get(app, '/secret.txt').first).to eq(404)
      expect(get(app, '/vendor/lib.js').first).to eq(404)
      expect(get(app, '/assets/secret.txt').first).to eq(404)
    end

    it 'does not widen the implicit public directory' do
      app_with_public = Otto.new(nil, { public: public_dir })
      app_with_public.mount_static('/vendor', root: vendor_dir)

      expect(get(app_with_public, '/vendor/lib.js').first).to eq(200)
      expect(get(app_with_public, '/index.html').first).to eq(200)
      # vendor/ is a sibling of public/, not inside it.
      expect(get(app_with_public, '/lib.js').first).to eq(404)
      expect(get(app_with_public, '/../vendor/lib.js').first).to eq(404)
    end

    it 'serves the canonical file, not the request path' do
      # The mount's Rack::Files is frozen, so observe the validated file that
      # the router hands to the serving step instead of stubbing the server.
      File.symlink(File.join(assets_dir, 'app.css'), File.join(assets_dir, 'alias.css'))
      allow(app).to receive(:serve_static_file).and_call_original

      get(app, '/assets/alias.css')

      expect(app).to have_received(:serve_static_file).with(
        anything,
        having_attributes(root: File.realpath(assets_dir), relative: 'app.css'),
        app.static_mounts.first.files
      )
    end
  end

  describe 'precedence' do
    it 'lets a literal route win over a mounted file at the same path' do
      routes = create_test_routes_file('mount_literal.txt', ['GET /assets/app.css TestApp.index'])
      app = Otto.new(routes)
      app.mount_static('/assets', root: assets_dir)

      expect(get(app, '/assets/app.css')).to include(200, 'Hello World')
      expect(get(app, '/assets/js/app.js')).to include(200, 'assets app.js')
    end

    it 'lets a mounted file win over the implicit public directory' do
      app = Otto.new(nil, { public: public_dir })
      app.mount_static('/assets', root: assets_dir)

      expect(get(app, '/assets/app.css')).to include(200, 'assets app.css')
      expect(get(app, '/index.html')).to include(200, 'public index')
    end

    it 'falls back to the public directory when no mount contains the file' do
      File.write(File.join(public_dir, 'assets', 'only-public.css'), 'only public')
      app = Otto.new(nil, { public: public_dir })
      app.mount_static('/assets', root: assets_dir)

      expect(get(app, '/assets/only-public.css')).to include(200, 'only public')
    end

    it 'lets a mounted file win over a dynamic route' do
      routes = create_test_routes_file('mount_dynamic.txt', ['GET /assets/:id TestApp.show'])
      app = Otto.new(routes)
      app.mount_static('/assets', root: assets_dir)

      expect(get(app, '/assets/app.css')).to include(200, 'assets app.css')
      expect(get(app, '/assets/missing.css')).to include(200, 'Showing missing.css')
    end

    it 'consults mounts longest prefix first and falls through to shorter ones' do
      FileUtils.mkdir_p(File.join(assets_dir, 'vendor'))
      File.write(File.join(assets_dir, 'vendor', 'shared.js'), 'from assets')
      File.write(File.join(vendor_dir, 'shared.js'), 'from vendor')
      app = Otto.new
      app.mount_static('/assets', root: assets_dir)
      app.mount_static('/assets/vendor', root: vendor_dir)

      expect(get(app, '/assets/vendor/shared.js')).to include(200, 'from vendor')
      expect(get(app, '/assets/vendor/lib.js')).to include(200, 'vendor lib.js')
      # Registration order does not affect the outcome.
      reversed = Otto.new
      reversed.mount_static('/assets/vendor', root: vendor_dir)
      reversed.mount_static('/assets', root: assets_dir)
      expect(get(reversed, '/assets/vendor/shared.js')).to include(200, 'from vendor')
    end

    it 'is independent of request history' do
      routes = create_test_routes_file('mount_history.txt', ['GET /assets/app.css TestApp.index'])
      app = Otto.new(routes)
      app.mount_static('/assets', root: assets_dir)

      first = get(app, '/assets/app.css')
      get(app, '/assets/js/app.js')
      second = get(app, '/assets/app.css')

      expect(first.last).to eq('Hello World')
      expect(second.last).to eq('Hello World')
    end
  end

  describe 'registration failures' do
    let(:app) { Otto.new }

    it 'rejects a missing root' do
      expect { app.mount_static('/assets', root: File.join(base, 'nope')) }
        .to raise_error(ArgumentError, /root .*nope.* cannot be resolved/)
    end

    it 'rejects a root that is a file' do
      expect { app.mount_static('/assets', root: File.join(base, 'secret.txt')) }
        .to raise_error(ArgumentError, /is not a directory/)
    end

    it 'rejects a root whose symlink dangles' do
      File.symlink(File.join(base, 'gone'), File.join(base, 'dangling'))

      expect { app.mount_static('/assets', root: File.join(base, 'dangling')) }
        .to raise_error(ArgumentError, /cannot be resolved/)
    end

    it 'rejects a root that is not a String' do
      expect { app.mount_static('/assets', root: nil) }
        .to raise_error(ArgumentError, /root must be a String/)
      expect { app.mount_static('/assets', root: '') }
        .to raise_error(ArgumentError, /root must not be empty/)
    end

    it 'rejects a root containing a NUL byte' do
      expect { app.mount_static('/assets', root: "#{assets_dir}\0") }
        .to raise_error(ArgumentError, /NUL byte/)
    end

    it 'requires the root keyword' do
      expect { app.mount_static('/assets') }.to raise_error(ArgumentError)
    end

    it 'rejects a prefix that does not start with a slash' do
      expect { app.mount_static('assets', root: assets_dir) }
        .to raise_error(ArgumentError, %r{must start with '/})
      expect { app.mount_static('', root: assets_dir) }
        .to raise_error(ArgumentError, %r{must start with '/})
    end

    it 'rejects a prefix that is not a String' do
      expect { app.mount_static(:assets, root: assets_dir) }
        .to raise_error(ArgumentError, /prefix must be a String/)
    end

    it 'rejects a prefix with empty, dot, or dot-dot segments' do
      ['/a//b', '/a/./b', '/a/../b', '/..', '/.'].each do |prefix|
        expect { app.mount_static(prefix, root: assets_dir) }
          .to raise_error(ArgumentError, /empty, '\.', or '\.\.' segments/), prefix
      end
    end

    it 'rejects a prefix containing a NUL byte' do
      expect { app.mount_static("/assets\0", root: assets_dir) }
        .to raise_error(ArgumentError, /NUL byte/)
    end

    it 'rejects a duplicate prefix, including one that only differs by a trailing slash' do
      app.mount_static('/assets', root: assets_dir)

      expect { app.mount_static('/assets', root: vendor_dir) }
        .to raise_error(ArgumentError, /already registered/)
      expect { app.mount_static('/assets/', root: vendor_dir) }
        .to raise_error(ArgumentError, /already registered/)
      expect(app.static_mounts.size).to eq(1)
    end

    it 'leaves the mount table untouched when a registration fails' do
      app.mount_static('/assets', root: assets_dir)
      before = app.static_mounts

      expect { app.mount_static('/vendor', root: File.join(base, 'nope')) }.to raise_error(ArgumentError)
      expect(app.static_mounts).to equal(before)
    end
  end

  describe 'configuration freezing' do
    it 'rejects registration after the configuration is frozen' do
      app = Otto.new
      app.mount_static('/assets', root: assets_dir)
      app.freeze_configuration!

      expect { app.mount_static('/vendor', root: vendor_dir) }
        .to raise_error(FrozenError, /Cannot modify frozen configuration/)
      expect(app.static_mounts.map(&:prefix)).to eq(['/assets'])
    end

    it 'keeps serving mounted files after freezing' do
      app = Otto.new
      app.mount_static('/assets', root: assets_dir)
      app.freeze_configuration!

      expect(app.static_mounts).to be_frozen
      expect(get(app, '/assets/app.css')).to include(200, 'assets app.css')
    end

    it 'serves concurrent requests across mounts after freezing' do
      count = 40
      count.times do |i|
        File.write(File.join(assets_dir, "a#{i}.txt"), "assets #{i}")
        File.write(File.join(vendor_dir, "v#{i}.txt"), "vendor #{i}")
      end
      app = Otto.new(nil, { public: public_dir })
      app.mount_static('/assets', root: assets_dir)
      app.mount_static('/assets/vendor', root: vendor_dir)
      app.freeze_configuration!

      errors = Queue.new
      threads = Array.new(count) do |i|
        Thread.new do # rubocop:disable ThreadSafety/NewThread
          expected = {
            "/assets/a#{i}.txt" => "assets #{i}",
            "/assets/vendor/v#{i}.txt" => "vendor #{i}",
            '/index.html' => 'public index',
          }
          expected.each do |path, content|
            status, _headers, body = get(app, path)
            errors << "#{path}: #{status} #{body}" unless status == 200 && body == content
          end
          status, = get(app, '/assets/../secret.txt')
          errors << "traversal served with #{status}" unless status == 404
        rescue StandardError => e
          errors << "#{e.class}: #{e.message}"
        end
      end
      threads.each(&:join)

      expect(errors.size).to eq(0), -> { Array.new(errors.size) { errors.pop }.join("\n") }
    end
  end

  describe 'instance isolation' do
    it 'keeps mounts private to the instance that registered them' do
      with_mount = Otto.new
      without_mount = Otto.new
      with_mount.mount_static('/assets', root: assets_dir)

      expect(get(with_mount, '/assets/app.css').first).to eq(200)
      expect(get(without_mount, '/assets/app.css').first).to eq(404)
      expect(without_mount.static_mounts).to be_empty
    end

    it 'lets two instances mount the same prefix on different roots' do
      first = Otto.new
      second = Otto.new
      first.mount_static('/files', root: assets_dir)
      second.mount_static('/files', root: vendor_dir)

      expect(get(first, '/files/app.css').first).to eq(200)
      expect(get(first, '/files/lib.js').first).to eq(404)
      expect(get(second, '/files/lib.js').first).to eq(200)
      expect(get(second, '/files/app.css').first).to eq(404)
    end
  end

  describe 'implicit public directory without mounts' do
    it 'is unchanged when nothing is registered' do
      app = Otto.new(nil, { public: public_dir })

      expect(app.static_mounts).to eq([])
      expect(get(app, '/index.html')).to include(200, 'public index')
      expect(get(app, '/assets/app.css')).to include(200, 'public app.css')
      expect(get(app, '/../secret.txt').first).to eq(404)
    end

    it 'no longer responds to the removed add_static_path' do
      expect(Otto.new).not_to respond_to(:add_static_path)
    end
  end
end
