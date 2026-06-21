# Rakefile
#
# frozen_string_literal: true

# `bundler/gem_tasks` defines the build/install/release tasks the
# release-gem.yml workflow drives via `bundle exec rake release`
# (RubyGems Trusted Publishing). `rake release` builds the gem, pushes the
# git tag (a no-op when the release tag already exists), and publishes to
# RubyGems.
require 'bundler/gem_tasks'

# Make `rake` (no task) run the specs, mirroring CI's `bundle exec rspec`.
# Guarded so `rake release` still works in an install without the test
# group (rspec lives in the :test group).
begin
  require 'rspec/core/rake_task'
  RSpec::Core::RakeTask.new(:spec)
  task default: :spec
rescue LoadError
  # rspec unavailable (e.g. a production/release-only bundle); skip the task.
end
