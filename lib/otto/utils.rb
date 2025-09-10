# frozen_string_literal: true

# lib/otto/utils.rb

class Otto
  # Utility methods for common operations and helpers
  module Utils
    extend self

    def yes?(value)
      !value.to_s.empty? && %w[true yes 1].include?(value.to_s.downcase)
    end
  end
end
