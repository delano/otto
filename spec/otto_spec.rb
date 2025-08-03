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

RSpec.describe Otto do
  it 'has organized test coverage across multiple spec files' do
    spec_files = Dir[File.join(__dir__, 'otto', '*.rb')]
    expected_files = %w[
      initialization_spec.rb
      security_spec.rb
      routing_spec.rb
      uri_spec.rb
      file_safety_spec.rb
      utilities_spec.rb
      request_helpers_spec.rb
    ]

    actual_files = spec_files.map { |f| File.basename(f) }.sort
    expect(actual_files).to match_array(expected_files)

    puts "\n=== Otto Test Suite Organization ==="
    actual_files.each { |file| puts "  ✓ #{file}" }
    puts "===================================\n"
  end
end
