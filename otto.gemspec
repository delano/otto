# -*- encoding: utf-8 -*-

require_relative 'lib/otto/version'

Gem::Specification.new do |spec|
  spec.name = "otto"
  spec.version = Otto::VERSION.to_s
  spec.summary = "Auto-define your rack-apps in plaintext."
  spec.description = "Otto: #{spec.summary}"
  spec.email = "gems@solutious.com"
  spec.authors = ["Delano Mandelbaum"]
  spec.license = "MIT"
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.homepage = "https://github.com/delano/otto"
  spec.require_paths = ["lib"]
  spec.rubygems_version = "3.5.15" # Update to the latest version

  spec.required_ruby_version = ['>= 2.6.8', '< 4.0']

  spec.add_runtime_dependency 'addressable', '~> 2.2', '< 3'
  spec.add_runtime_dependency 'rack', '~> 2.2', '< 3.0'
end
