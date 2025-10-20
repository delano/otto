# Gemfile

# To install all development and test dependencies:
#
#   $ bundle config set with 'development test'
#   $ bundle install

source 'https://rubygems.org'

gemspec

gem 'rackup'

group :test do
  gem 'rack-test'
  gem 'rspec', '~> 3.13'
end

# bundle config set with 'optional'
group :development, :test, optional: true do
  # Keep gems that need to be in both environments
  gem 'json_schemer'
  gem 'rack-attack'
end

group :development do
  gem 'benchmark'
  gem 'debug'
  gem 'rubocop', '~> 1.81.1', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rspec', require: false
  gem 'rubocop-thread_safety', require: false
  gem 'ruby-lsp', require: false
  gem 'stackprof', require: false
  gem 'syntax_tree', require: false
  gem 'tryouts', '~> 3.7.1', require: false
end
