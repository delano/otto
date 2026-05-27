# otto.gemspec

require_relative 'lib/otto/version'

Gem::Specification.new do |spec|
  spec.name          = 'otto'
  spec.version       = Otto::VERSION.to_s
  spec.summary       = 'Define your rack-apps in plaintext.'
  spec.description   = "Otto: #{spec.summary}"
  spec.email         = 'gems@solutious.com'
  spec.authors       = ['Delano Mandelbaum']
  spec.license       = 'MIT'
  spec.files         = if File.directory?('.git') && system('git --version > /dev/null 2>&1')
                         `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
                       else
                         Dir['**/*'].select { |f| File.file?(f) }.reject { |f| f.match(%r{^(test|spec|features)/}) }
                       end
  spec.homepage      = 'https://github.com/delano/otto'
  spec.require_paths = ['lib']

  spec.required_ruby_version = ['>= 3.2', '< 4.1']

  spec.add_dependency 'concurrent-ruby', '~> 1.3', '< 2.0'

  # ipaddr is a default gem on every supported Ruby (3.2+), so `require
  # 'ipaddr'` works without a gemspec dependency. Declaring one collides
  # with bundler 2.7.x's default-gem handling: the lockfile pins a version
  # newer than the activated default and bundler refuses to swap, breaking
  # `bundle exec` (including `rake release`). Drop the declaration and
  # rely on the runtime default gem until bundler ships default-gem
  # override support for ipaddr.

  # Logger is not part of the default gems as of Ruby 3.5.0
  spec.add_dependency 'logger', '~> 1', '< 2.0'

  spec.add_dependency 'rack', '~> 3.1', '< 4.0'
  spec.add_dependency 'rack-parser', '~> 0.7'
  spec.add_dependency 'rexml', '~> 3.4'

  # Security dependencies
  spec.add_dependency 'loofah', '~> 2.20'

  # Optional MCP dependencies
  # spec.add_dependency 'json_schemer', '~> 2.0'
  # spec.add_dependency 'rack-attack', '~> 6.7'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
