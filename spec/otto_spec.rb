# spec/otto_spec.rb
#
# frozen_string_literal: true

require 'spec_helper'

# This file orchestrates the Otto test suite by including all organized test files.
# Individual test files are organized by functionality in the spec/otto/ directory:
#
# - initialization_spec.rb: Otto instantiation, configuration, and class methods
# - security_spec.rb: Security features, headers, middleware, and trusted proxies
# - routing_spec.rb: Request handling, routing, and error handling
# - uri_spec.rb: URI generation with comprehensive edge case coverage
# - file_safety_spec.rb: File and directory safety validation
# - utilities_spec.rb: Locale handling and other utility methods
# - enhanced_routing_spec.rb: Enhanced route parsing with key-value parameters
# - response_handlers_spec.rb: Response handler system unit tests
# - response_integration_spec.rb: Response handler integration tests

RSpec.describe Otto do
  it 'has organized test coverage with proper naming conventions' do
    spec_files = Dir[File.join(__dir__, 'otto', '*.rb')]
    actual_files = spec_files.map { |f| File.basename(f) }.sort

    # Verify we have at least the core test files
    core_patterns = [
      /_spec\.rb$/, # All files should end with _spec.rb
      /initialization_spec/, # Core initialization tests
      /routing_spec/, # Core routing tests
      /security_spec/, # Core security tests
    ]

    core_patterns.each do |pattern|
      matching_files = actual_files.select { |f| f.match?(pattern) }
      expect(matching_files).not_to be_empty,
                                    "Expected to find test files matching pattern #{pattern.inspect}"
    end

    # Ensure minimum test file count (prevents accidental deletion of test suites)
    expect(actual_files.size).to be >= 8,
                                 "Expected at least 8 test files, found #{actual_files.size}"

    puts "\n=== Otto Test Suite Organization (#{actual_files.size} files) ==="
    actual_files.each { |file| puts "  ✓ #{file}" }
    puts "===================================\n"
  end
end
