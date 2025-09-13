# otto.gemspec

require_relative 'lib/otto/version'

Gem::Specification.new do |spec|
  spec.name          = 'otto'
  spec.version       = Otto::VERSION.to_s
  spec.summary       = 'Auto-define your rack-apps in plaintext.'
  spec.description   = "Otto: #{spec.summary}"
  spec.email         = 'gems@solutious.com'
  spec.authors       = ['Delano Mandelbaum']
  spec.license       = 'MIT'
  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.homepage      = 'https://github.com/delano/otto'
  spec.require_paths = ['lib']

  spec.required_ruby_version = ['>= 3.2', '< 4.0']


  spec.add_dependency 'rack', '~> 3.1', '< 4.0'
  spec.add_dependency 'rack-parser', '~> 0.7'
  spec.add_dependency 'rexml', '>= 3.3.6'

  # Security dependencies
  spec.add_dependency 'facets', '~> 3.1'
  spec.add_dependency 'loofah', '~> 2.20'

  # Optional MCP dependencies
  # spec.add_dependency 'json_schemer', '~> 2.0'
  # spec.add_dependency 'rack-attack', '~> 6.7'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
