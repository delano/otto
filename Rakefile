require "rubygems"
require "rake"
require "rake/clean"
require 'yaml'

require 'rdoc/task'

config = YAML.load_file("VERSION.yml")
task :default => ["build"]
CLEAN.include [ 'pkg', 'doc' ]
name = "otto"

begin
  require "jeweler"
  Jeweler::Tasks.new do |gem|
    gem.version = "#{config[:MAJOR]}.#{config[:MINOR]}.#{config[:PATCH]}"
    gem.name = "otto"
    gem.rubyforge_project = gem.name
    gem.summary = "Auto-define your rack-apps in plaintext."
    gem.description = "Auto-define your rack-apps in plaintext."
    gem.email = "delano@solutious.com"
    gem.homepage = "http://github.com/delano/otto"
    gem.authors = ["Delano Mandelbaum"]
    gem.add_dependency('rack',          '>= 1.2.1')
    gem.add_dependency('addressable',    '>= 2.2.6')
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: sudo gem install jeweler"
end


RDoc::Task.new do |rdoc|
  version = "#{config[:MAJOR]}.#{config[:MINOR]}.#{config[:PATCH]}"
  rdoc.rdoc_dir = "doc"
  rdoc.title = "otto #{version}"
  rdoc.rdoc_files.include("README*")
  rdoc.rdoc_files.include("LICENSE.txt")
  rdoc.rdoc_files.include("bin/*.rb")
  rdoc.rdoc_files.include("lib/**/*.rb")
end


