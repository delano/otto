# lib/otto/utils.rb
#
# frozen_string_literal: true

class Otto
  # Utility methods for common operations and helpers
  module Utils
    extend self

    # @return [Time] Current time in UTC
    def now
      Time.now.utc
    end

    # Returns the current time in microseconds.
    # This is used to measure the duration of Database commands.
    #
    # Alias: now_in_microseconds
    #
    # @return [Integer] The current time in microseconds.
    def now_in_μs
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
    end
    alias now_in_microseconds now_in_μs

    # Determine if a value represents a "yes" or true value
    #
    # @param value [Object] The value to evaluate
    # @return [Boolean] True if the value represents "yes", false otherwise
    #
    # Examples:
    # yes?('true')  # => true
    # yes?('yes')   # => true
    # yes?('1')     # => true
    def yes?(value)
      !value.to_s.empty? && %w[true yes 1].include?(value.to_s.downcase)
    end
  end
end
