# lib/otto/utils.rb

class Otto
  # Utility methods for common operations and helpers
  module Utils
    extend self

    # @return [Time] Current time in UTC
    def now
      Time.now.utc
    end

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
