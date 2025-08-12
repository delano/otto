source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'rack-test'
  gem 'rspec', '~> 3.12'
end

# bundle config set with 'optional'
group :development, :test, optional: true do
  gem 'json_schemer'
  gem 'rack-attack'
end

group :development do
  gem 'pry-byebug', require: false
  gem 'rubocop', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rspec', require: false
  gem 'rubocop-thread_safety', require: false
  gem 'ruby-lsp', require: false
  gem 'stackprof', require: false
  gem 'syntax_tree', require: false
  gem 'tryouts', '~> 3.3.2', require: false
end
