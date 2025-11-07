# frozen_string_literal: true
# spec/otto/file_safety_spec.rb

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
      # The file needs to be owned by the current user/group for safe_file? to return true
      if File.exist?('/tmp/test_public/safe.txt') &&
         (File.owned?('/tmp/test_public/safe.txt') || File.grpowned?('/tmp/test_public/safe.txt'))
        expect(otto.safe_file?('safe.txt')).to be true
      else
        expect(otto.safe_file?('safe.txt')).to be false
      end
      expect(otto.safe_file?('nonexistent.txt')).to be false
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
end
