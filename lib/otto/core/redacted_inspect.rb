# lib/otto/core/redacted_inspect.rb
#
# frozen_string_literal: true

class Otto
  module Core
    # Kernel#inspect-style output that masks secret-bearing instance variables.
    #
    # Ruby's default #inspect prints every instance variable, and a native
    # FrozenError raised on a frozen object embeds the receiver's #inspect in
    # its message, so a secret held in an ivar reaches any log that records
    # the error. An including class lists the ivars to mask by overriding
    # #inspect_redacted_ivars. A masked ivar prints as [REDACTED] unless it is
    # nil; an empty String is still a key, so it is masked too.
    #
    # The string is built without writing to the receiver, so it is safe on a
    # frozen instance. PP uses a class's own #inspect when one is defined, so
    # `pp` output is masked the same way.
    #
    # @example
    #   class TokenHolder
    #     include Otto::Core::RedactedInspect
    #
    #     private
    #
    #     def inspect_redacted_ivars
    #       %i[@token].freeze
    #     end
    #   end
    module RedactedInspect
      REDACTED = '[REDACTED]'

      KERNEL_TO_S = Kernel.instance_method(:to_s)
      private_constant :KERNEL_TO_S

      # @return [String] default-format inspect with secret ivars masked
      def inspect
        fields = instance_variables.map { |name| "#{name}=#{inspect_ivar_value(name)}" }
        prefix = KERNEL_TO_S.bind_call(self).delete_suffix('>')
        fields.empty? ? "#{prefix}>" : "#{prefix} #{fields.join(', ')}>"
      end

      private

      # Instance variable names whose values #inspect masks.
      #
      # @return [Array<Symbol>]
      def inspect_redacted_ivars
        [].freeze
      end

      def inspect_ivar_value(name)
        value = instance_variable_get(name)
        return value.inspect if value.nil? || !inspect_redacted_ivars.include?(name)

        REDACTED
      end
    end
  end
end
