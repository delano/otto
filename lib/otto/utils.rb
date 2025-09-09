# lib/otto/utils.rb

class Otto
  module Utils
    def yes?(value)
      !value.to_s.empty? && %w[true yes 1].include?(value.to_s.downcase)
    end
  end
end
