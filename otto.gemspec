# -*- encoding: utf-8 -*-

Gem::Specification.new do |spec|
  spec.name = "otto"
  spec.version = "1.0.1"
  spec.summary = "Auto-define your rack-apps in plaintext."
  spec.description = "Otto: #{spec.summary}"
  spec.email = "gems@solutious.com"
  spec.authors = ["Delano Mandelbaum"]
  spec.license = "MIT"
  spec.files = [
    "LICENSE.txt",
    "README.md",
    "Rakefile",
    "VERSION.yml",
    "example/app.rb",
    "example/config.ru",
    "example/public/favicon.ico",
    "example/public/img/otto.jpg",
    "example/routes",
    "lib/otto.rb",
    "otto.gemspec"
  ]
  spec.homepage = "https://github.com/delano/otto"
  spec.require_paths = ["lib"]
  spec.rubygems_version = "3.2.22" # Update to the latest version

  spec.required_ruby_version = ['>= 2.6.8', '< 4.0']

  spec.add_dependency 'rack'
  spec.add_dependency 'addressable'

  spec.add_dependency 'addressable', '>= 2.2.6'
  spec.add_dependency 'rack', '>= 1.2.1'
end
