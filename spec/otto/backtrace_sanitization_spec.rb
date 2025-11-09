# frozen_string_literal: true

require 'spec_helper'
require 'otto/logging_helpers'

RSpec.describe 'Otto::LoggingHelpers backtrace sanitization' do
  let(:project_root) { '/Users/alice/projects/myapp' }

  describe '.sanitize_backtrace_line' do
    it 'converts project files to relative paths' do
      line = '/Users/alice/projects/myapp/app/controllers/users_controller.rb:42:in `create\''
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('app/controllers/users_controller.rb:42:in `create\'')
    end

    it 'handles bundler gems with git hashes' do
      line = '/Users/alice/.rbenv/versions/3.4.7/lib/ruby/gems/3.4.0/bundler/gems/otto-34f285412a44/lib/otto/route.rb:142:in `call\''
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('[GEM] otto/lib/otto/route.rb:142:in `call\'')
    end

    it 'handles regular gems and strips version numbers' do
      line = '/Users/alice/.rbenv/versions/3.4.7/lib/ruby/gems/3.4.0/gems/rack-3.2.4/lib/rack/builder.rb:310:in `call\''
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('[GEM] rack/lib/rack/builder.rb:310:in `call\'')
    end

    it 'handles gems with version directories (nested gems)' do
      line = '/opt/ruby/3.4.7/lib/ruby/gems/3.4.0/gems/sentry-ruby-5.28.0/lib/sentry/hub.rb:89:in `with_scope\''
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('[GEM] sentry-ruby/lib/sentry/hub.rb:89:in `with_scope\'')
    end

    it 'handles multi-hyphenated gem names correctly' do
      line = '/path/to/gems/active-record-import-1.5.0/lib/active_record/import.rb:10:in `import\''
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('[GEM] active-record-import/lib/active_record/import.rb:10:in `import\'')
    end

    it 'handles Ruby stdlib files' do
      line = '/Users/alice/.rbenv/versions/3.4.7/lib/ruby/3.4.0/logger.rb:310:in `add\''
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('[RUBY] logger.rb:310:in `add\'')
    end

    it 'handles unknown external files' do
      line = '/some/unknown/path/file.rb:50:in `method\''
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('[EXTERNAL] file.rb:50:in `method\'')
    end

    it 'handles backtrace lines without method names' do
      line = '/Users/alice/projects/myapp/config.ru:10'
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('config.ru:10')
    end

    it 'handles malformed paths gracefully' do
      line = "invalid\x00path.rb:10:in `method\'"
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      # Malformed paths are handled safely - we show the filename even with null bytes
      # This is better than crashing, and the null byte is still visible for debugging
      expect(result).to eq("[EXTERNAL] invalid\x00path.rb:10:in `method\'")
    end

    it 'returns line as-is if it cannot be parsed' do
      line = 'not a backtrace line'
      result = Otto::LoggingHelpers.sanitize_backtrace_line(line, project_root)
      expect(result).to eq('not a backtrace line')
    end

    it 'handles nil input' do
      result = Otto::LoggingHelpers.sanitize_backtrace_line(nil, project_root)
      expect(result).to be_nil
    end

    it 'handles empty string input' do
      result = Otto::LoggingHelpers.sanitize_backtrace_line('', project_root)
      expect(result).to eq('')
    end
  end

  describe '.sanitize_backtrace' do
    let(:backtrace) do
      [
        '/Users/alice/projects/myapp/app/models/user.rb:10:in `save\'',
        '/Users/alice/.rbenv/versions/3.4.7/lib/ruby/gems/3.4.0/bundler/gems/otto-34f285412a44/lib/otto.rb:118:in `call\'',
        '/Users/alice/.rbenv/versions/3.4.7/lib/ruby/gems/3.4.0/gems/rack-3.2.4/lib/rack.rb:20:in `call\'',
        '/Users/alice/.rbenv/versions/3.4.7/lib/ruby/3.4.0/logger.rb:310:in `add\''
      ]
    end

    it 'sanitizes entire backtrace array' do
      result = Otto::LoggingHelpers.sanitize_backtrace(backtrace, project_root: project_root)
      expect(result).to eq([
        'app/models/user.rb:10:in `save\'',
        '[GEM] otto/lib/otto.rb:118:in `call\'',
        '[GEM] rack/lib/rack.rb:20:in `call\'',
        '[RUBY] logger.rb:310:in `add\''
      ])
    end

    it 'handles nil backtrace' do
      result = Otto::LoggingHelpers.sanitize_backtrace(nil, project_root: project_root)
      expect(result).to eq([])
    end

    it 'handles empty backtrace' do
      result = Otto::LoggingHelpers.sanitize_backtrace([], project_root: project_root)
      expect(result).to eq([])
    end

    it 'auto-detects project root if not provided' do
      allow(Otto::LoggingHelpers).to receive(:detect_project_root).and_return(project_root)
      result = Otto::LoggingHelpers.sanitize_backtrace(backtrace)
      expect(result.length).to eq(4)
      expect(result.first).to eq('app/models/user.rb:10:in `save\'')
    end
  end

  describe 'security properties' do
    let(:sensitive_backtrace) do
      [
        '/home/admin/secret-project/app/auth.rb:100:in `authenticate\'',
        '/home/admin/.rvm/gems/ruby-3.4.0/gems/bcrypt-3.1.18/lib/bcrypt.rb:50:in `verify\''
      ]
    end

    it 'does not expose absolute paths in output' do
      result = Otto::LoggingHelpers.sanitize_backtrace(sensitive_backtrace,
                                                        project_root: '/home/admin/secret-project')
      result.each do |line|
        expect(line).not_to match(%r{^/home/})
        expect(line).not_to match(%r{^/Users/})
      end
    end

    it 'does not expose usernames in output' do
      result = Otto::LoggingHelpers.sanitize_backtrace(sensitive_backtrace,
                                                        project_root: '/home/admin/secret-project')
      result.each do |line|
        expect(line).not_to include('admin')
        expect(line).not_to include('/home/')
      end
    it 'does not expose project names' do
      result = Otto::LoggingHelpers.sanitize_backtrace(sensitive_backtrace,
                                                        project_root: '/home/admin/secret-project')
      # Project file path should be relative, not contain project name
      expect(result[0]).to eq("app/auth.rb:100:in `authenticate'")
      # Gem paths should not contain project name
      expect(result[1]).not_to include('secret-project')
    end
      end
    end
  end
end
