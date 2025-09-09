# frozen_string_literal: true

require 'bundler/setup'
require 'rack'
require 'rack/test'
require 'json'

# Load Otto
require_relative '../lib/otto'

# Configure Otto for testing
Otto.debug = ENV['OTTO_DEBUG'] == 'true'
Otto.logger.level = Logger::WARN unless Otto.debug

RSpec.configure do |config|
  config.mock_with :rspec do |mocks|
    # When enabled, RSpec will:
    #
    # - Verify that stubbed methods actually exist on the real object
    # - Check method arity (number of arguments) matches
    # - Ensure you're not stubbing non-existent methods
    #
    mocks.verify_partial_doubles = true
  end

  # Applies shared context metadata to host groups, enhancing test organization.
  # Will be default in RSpec 4
  config.shared_context_metadata_behavior = :apply_to_host_groups

  # RSpec will create this file to keep track of example statuses, and
  # powers the the --only-failures flag.
  config.example_status_persistence_file_path = 'spec/.rspec_status'

  # Suppresses Ruby warnings during test runs for a cleaner output.
  config.warnings = true

  # Disable RSpec exposing methods globally on Module and main
  config.disable_monkey_patching!

  # Use expect syntax instead of should
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Include Rack::Test helpers
  config.include Rack::Test::Methods

  # Set up clean environment for each test
  config.before(:each) do
    # Reset environment variables
    ENV['RACK_ENV'] = 'test'
    ENV['OTTO_DEBUG'] = 'false' unless ENV['OTTO_DEBUG'] == 'true'

    # Clean up any test files in spec/fixtures
    Dir.glob('spec/fixtures/test_routes_*.txt').each { |f| File.delete(f) if File.exist?(f) }
  end

  config.after(:each) do
    # Clean up any test files created during tests in spec/fixtures
    Dir.glob('spec/fixtures/test_routes_*.txt').each { |f| File.delete(f) if File.exist?(f) }
  end

  # Configure output format
  config.color = true
  config.tty = true
  config.formatter = :documentation

  # Random order by default
  config.order = :random
  Kernel.srand config.seed
end

# Load support files
Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.include OttoTestHelpers
end
