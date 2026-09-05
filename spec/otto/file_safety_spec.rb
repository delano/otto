# spec/otto/file_safety_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Otto, 'file safety checks' do
  subject(:otto) { described_class.new(nil, { public: '/tmp/test_public' }) }

  before do
    Dir.mkdir('/tmp/test_public') unless Dir.exist?('/tmp/test_public')
    File.write('/tmp/test_public/safe.txt', 'safe content')
  end

  after do
    FileUtils.rm_rf('/tmp/test_public') if Dir.exist?('/tmp/test_public')
  end

  describe '#safe_file?' do
    it 'returns false when public dir is not set' do
      otto_no_public = described_class.new
      expect(otto_no_public.safe_file?('any/path')).to be false
    end

    it 'returns false for nil or empty paths' do
      expect(otto.safe_file?(nil)).to be false
      expect(otto.safe_file?('')).to be false
      expect(otto.safe_file?('   ')).to be false
    end

    it 'prevents path traversal attacks' do
      expect(otto.safe_file?('../../../etc/passwd')).to be false
      expect(otto.safe_file?('..\\..\\windows\\system32')).to be false
      expect(otto.safe_file?('/etc/passwd')).to be false
    end

    it 'removes null bytes from paths' do
      expect(otto.safe_file?("safe.txt\0../../../etc/passwd")).to be false
    end

    it 'validates file existence and permissions' do
      # mktmpdir files are always owned by the current user, so this is a hard
      # expectation rather than an ownership-conditional one.
      dir = Dir.mktmpdir('otto_public')
      File.write(File.join(dir, 'safe.txt'), 'safe content')
      app = described_class.new(nil, { public: dir })

      expect(app.safe_file?('safe.txt')).to be true
      expect(app.safe_file?('nonexistent.txt')).to be false
    ensure
      FileUtils.remove_entry(dir) if dir && File.exist?(dir)
    end

    it 'rejects a NUL byte outright instead of repairing the path' do
      expect(otto.safe_file?("safe.txt\0")).to be false
      expect(otto.safe_file?("\0safe.txt")).to be false
    end

    it 'rejects directories' do
      expect(otto.safe_file?('.')).to be false
      expect(otto.safe_file?('..')).to be false
    end
  end

  describe '#safe_dir?' do
    it 'returns false for nil or empty paths' do
      expect(otto.safe_dir?(nil)).to be false
      expect(otto.safe_dir?('')).to be false
    end

    it 'validates directory existence and permissions' do
      expect(otto.safe_dir?('/tmp/test_public')).to be true
      expect(otto.safe_dir?('/nonexistent/directory')).to be false
    end

    it 'removes null bytes from paths' do
      expect(otto.safe_dir?("/tmp/test_public\0")).to be true
    end
  end

  # Regression coverage for issue #257: a symlink under the public directory
  # could point at a same-user file outside that directory and still pass the
  # lexical File.expand_path prefix check -- an end-to-end probe served the
  # external file with HTTP 200. Containment is now decided on canonical
  # (File.realpath) paths.
  describe 'symlink containment' do
    subject(:otto) { described_class.new(nil, { public: public_dir }) }

    let(:public_dir) { Dir.mktmpdir('otto_public') }
    let(:outside_dir) { Dir.mktmpdir('otto_outside') }

    before do
      File.write(File.join(outside_dir, 'secret.txt'), 'SECRET')
      File.write(File.join(public_dir, 'asset.txt'), 'asset content')
    end

    after do
      FileUtils.remove_entry(public_dir) if File.exist?(public_dir)
      FileUtils.remove_entry(outside_dir) if File.exist?(outside_dir)
    end

    it 'rejects a symlink pointing at a file outside the public directory' do
      File.symlink(File.join(outside_dir, 'secret.txt'), File.join(public_dir, 'link.txt'))

      expect(otto.safe_file?('/link.txt')).to be false
    end

    it 'rejects a file reached through a symlinked directory component' do
      File.symlink(outside_dir, File.join(public_dir, 'escape'))

      expect(otto.safe_file?('/escape/secret.txt')).to be false
    end

    it 'rejects a symlink chain whose final target escapes the root' do
      File.symlink(File.join(outside_dir, 'secret.txt'), File.join(outside_dir, 'hop.txt'))
      File.symlink(File.join(outside_dir, 'hop.txt'), File.join(public_dir, 'chain.txt'))

      expect(otto.safe_file?('/chain.txt')).to be false
    end

    it 'allows a symlink whose target resolves back inside the root' do
      File.symlink(File.join(public_dir, 'asset.txt'), File.join(public_dir, 'alias.txt'))

      expect(otto.safe_file?('/alias.txt')).to be true
    end

    it 'rejects a dangling symlink' do
      File.symlink(File.join(outside_dir, 'missing.txt'), File.join(public_dir, 'dangling.txt'))

      expect(otto.safe_file?('/dangling.txt')).to be false
    end

    it 'rejects a symlink loop without raising' do
      File.symlink(File.join(public_dir, 'b.txt'), File.join(public_dir, 'a.txt'))
      File.symlink(File.join(public_dir, 'a.txt'), File.join(public_dir, 'b.txt'))

      expect { otto.safe_file?('/a.txt') }.not_to raise_error
      expect(otto.safe_file?('/a.txt')).to be false
    end

    it 'rejects a sibling-prefixed directory that is not inside the root' do
      sibling = "#{public_dir}_evil"
      FileUtils.mkdir_p(sibling)
      File.write(File.join(sibling, 'secret.txt'), 'SECRET')
      File.symlink(sibling, File.join(public_dir, 'sib'))

      expect(otto.safe_file?('/sib/secret.txt')).to be false
    ensure
      FileUtils.remove_entry(sibling) if sibling && File.exist?(sibling)
    end

    it 'rejects a lexically contained path whose realpath escapes' do
      File.symlink(outside_dir, File.join(public_dir, 'deep'))

      # No '..' anywhere: expand_path alone considers this contained.
      expect(otto.safe_file?('/deep/secret.txt')).to be false
    end

    it 'still serves files when the public root is itself a symlink' do
      real_root = Dir.mktmpdir('otto_real_root')
      File.write(File.join(real_root, 'asset.txt'), 'via symlinked root')
      link_root = File.join(Dir.mktmpdir('otto_link_parent'), 'public')
      File.symlink(real_root, link_root)

      app = described_class.new(nil, { public: link_root })

      expect(app.safe_file?('/asset.txt')).to be true
      expect(app.safe_dir?(link_root)).to be true
    ensure
      [real_root, link_root && File.dirname(link_root)].compact.each do |d|
        FileUtils.remove_entry(d) if File.exist?(d)
      end
    end
  end

  # Static dispatch must validate every candidate before serving it. An
  # escaping symlink dropped next to an already-served asset must not inherit
  # approval from the prior request.
  describe 'static dispatch containment (issue #257)' do
    let(:public_dir) { Dir.mktmpdir('otto_public') }
    let(:outside_dir) { Dir.mktmpdir('otto_outside') }

    let(:app) do
      FileUtils.mkdir_p(File.join(public_dir, 'assets'))
      File.write(File.join(public_dir, 'assets', 'ok.txt'), 'ok')
      File.write(File.join(outside_dir, 'secret.txt'), 'SECRET')
      described_class.new(nil, { public: public_dir })
    end

    after do
      FileUtils.remove_entry(public_dir) if File.exist?(public_dir)
      FileUtils.remove_entry(outside_dir) if File.exist?(outside_dir)
    end

    it 'serves a contained static file' do
      status, _headers, body = app.call(Rack::MockRequest.env_for('/assets/ok.txt'))

      expect(status).to eq(200)
      expect(body.to_enum(:each).to_a.join).to eq('ok')
    end

    it 'does not serve an escaping symlink after serving a sibling file' do
      expect(app.call(Rack::MockRequest.env_for('/assets/ok.txt'))[0]).to eq(200)

      File.symlink(outside_dir, File.join(public_dir, 'assets', 'esc'))
      status, _headers, body = app.call(Rack::MockRequest.env_for('/assets/esc/secret.txt'))

      expect(status).to eq(404)
      expect(body.to_enum(:each).to_a.join).not_to include('SECRET')
    end

    it 'does not serve an escaping symlink on the first request' do
      File.symlink(File.join(outside_dir, 'secret.txt'), File.join(public_dir, 'link.txt'))

      status, _headers, body = app.call(Rack::MockRequest.env_for('/link.txt'))

      expect(status).to eq(404)
      expect(body.to_enum(:each).to_a.join).not_to include('SECRET')
    end

    it 'serves through a canonical Rack::Files root when the public root is a symlink' do
      real_root = Dir.mktmpdir('otto_real_root')
      File.write(File.join(real_root, 'asset.txt'), 'via symlinked root')
      link_root = File.join(Dir.mktmpdir('otto_link_parent'), 'public')
      File.symlink(real_root, link_root)
      linked_app = described_class.new(nil, { public: link_root })

      status, _headers, body = linked_app.call(Rack::MockRequest.env_for('/asset.txt'))

      expect(status).to eq(200)
      expect(body.to_enum(:each).to_a.join).to eq('via symlinked root')
      expect(linked_app.send(:build_static_route).root).to eq(File.realpath(real_root))
    ensure
      [real_root, link_root && File.dirname(link_root)].compact.each do |d|
        FileUtils.remove_entry(d) if File.exist?(d)
      end
    end

    # Deploys commonly flip a 'current' symlink to a new release without a
    # restart. Containment resolves the root per request, but the memoised
    # Rack::Files must follow it, or the old tree keeps being served (and a
    # validated relative path is joined to a root it was never checked against).
    it 'follows the public root symlink when it is repointed between requests' do
      release_a = Dir.mktmpdir('otto_release_a')
      release_b = Dir.mktmpdir('otto_release_b')
      File.write(File.join(release_a, 'asset.txt'), 'release A')
      File.write(File.join(release_b, 'asset.txt'), 'release B')
      File.write(File.join(release_b, 'new.txt'), 'only in B')
      link_root = File.join(Dir.mktmpdir('otto_link_parent'), 'current')
      File.symlink(release_a, link_root)
      linked_app = described_class.new(nil, { public: link_root })

      status, _headers, body = linked_app.call(Rack::MockRequest.env_for('/asset.txt'))
      expect(status).to eq(200)
      expect(body.to_enum(:each).to_a.join).to eq('release A')
      expect(linked_app.static_route.root).to eq(File.realpath(release_a))

      # Atomic repoint: symlink to a temp name, then rename over the old link.
      tmp_link = "#{link_root}.tmp"
      File.symlink(release_b, tmp_link)
      File.rename(tmp_link, link_root)

      status, _headers, body = linked_app.call(Rack::MockRequest.env_for('/asset.txt'))
      expect(status).to eq(200)
      expect(body.to_enum(:each).to_a.join).to eq('release B')
      expect(linked_app.static_route.root).to eq(File.realpath(release_b))

      status, _headers, body = linked_app.call(Rack::MockRequest.env_for('/new.txt'))
      expect(status).to eq(200)
      expect(body.to_enum(:each).to_a.join).to eq('only in B')
    ensure
      [release_a, release_b, link_root && File.dirname(link_root)].compact.each do |d|
        FileUtils.remove_entry(d) if d && File.exist?(d)
      end
    end

    it 'returns 404 rather than raising when the public root does not exist' do
      missing_app = described_class.new(nil, { public: '/nonexistent/otto/public' })

      expect { missing_app.call(Rack::MockRequest.env_for('/asset.txt')) }.not_to raise_error
      expect(missing_app.call(Rack::MockRequest.env_for('/asset.txt'))[0]).to eq(404)
    end

    it 'serves files whose names need escaping through the canonical path rewrite' do
      File.write(File.join(public_dir, 'a b%c.txt'), 'spaced')

      status, _headers, body = app.call(Rack::MockRequest.env_for('/a%20b%25c.txt'))

      expect(status).to eq(200)
      expect(body.to_enum(:each).to_a.join).to eq('spaced')
    end
  end
end
