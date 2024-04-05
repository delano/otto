# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = "otto"
  s.version = "1.0.0"
  s.summary = "Auto-define your rack-apps in plaintext."
  s.description = "Otto: #{s.summary}"
  s.email = "gems@solutious.com"
  s.authors = ["Delano Mandelbaum"]
  s.license = "MIT"
  s.files = [
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
  s.homepage = "https://github.com/delano/otto"
  s.require_paths = ["lib"]
  s.rubygems_version = "3.2.22" # Update to the latest version

  s.required_ruby_version = '>= 2.6.8'

  s.add_dependency 'addressable', '~> 2.2', '>= 2.2.6'
  s.add_dependency 'rack', '~> 1.2', '>= 1.2.1'
end
