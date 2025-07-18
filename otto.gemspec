require_relative 'lib/otto/version'

Gem::Specification.new do |spec|
  spec.name = 'otto'
  spec.version = Otto::VERSION.to_s
  spec.summary = 'Auto-define your rack-apps in plaintext.'
  spec.description = "Otto: #{spec.summary}"
  spec.email = 'gems@solutious.com'
  spec.authors = ['Delano Mandelbaum']
  spec.license = 'MIT'
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.homepage = 'https://github.com/delano/otto'
  spec.require_paths = ['lib']

  spec.required_ruby_version = ['>= 3.4', '< 4.0']

  # https://github.com/delano/otto/security/dependabot/5
  spec.add_dependency 'rexml', '>= 3.3.6'

  spec.add_dependency 'addressable', '~> 2.2', '< 3'
  spec.add_dependency 'rack', '~> 3.1', '< 4.0'
  spec.add_dependency 'rack-parser', '~> 0.7'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
