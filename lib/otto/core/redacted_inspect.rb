# lib/otto/core/redacted_inspect.rb
#
# frozen_string_literal: true

class Otto
  module Core
    # An #inspect in the format of Object#inspect that leaves out secret
    # values. Ruby's FrozenError message embeds the receiver's #inspect, so a
    # write to a frozen object that holds a secret would otherwise put the
    # secret in the exception message, and from there in logs.
    #
    # Including classes override #redacted_inspect_value for the instance
    # variables that hold secrets and return the placeholder from
    # #redacted_placeholder instead of the value.
    #
    # @example
    #   class Holder
    #     include Otto::Core::RedactedInspect
    #
    #     private
    #
    #     def redacted_inspect_value(ivar, value)
    #       ivar == :@secret ? redacted_placeholder(value) : super
    #     end
    #   end
    module RedactedInspect
      # Stands in for a redacted value in #inspect output.
      PLACEHOLDER = '[REDACTED]'

      # A String whose #inspect is PLACEHOLDER. Content, #to_s, ==, eql? and
      # hash are String's, so it compares, hashes and interpolates as the
      # secret it holds. A write to a frozen one raises a FrozenError whose
      # message shows the placeholder.
      class SecretString < String
        # @return [String] PLACEHOLDER
        def inspect
          PLACEHOLDER
        end
      end

      # An Array of secrets whose #inspect (and #to_s, which Array aliases to
      # its C inspect) shows PLACEHOLDER and the element count. Element access,
      # ==, include? and iteration are Array's. A write to a frozen one raises
      # a FrozenError whose message shows the placeholder.
      class SecretList < Array
        # @return [String] "[REDACTED] (N)"
        def inspect
          "#{PLACEHOLDER} (#{size})"
        end
        alias to_s inspect
      end

      # Wrap a secret so its #inspect is redacted: a String becomes a
      # SecretString, an Array a SecretList of SecretStrings. Other values
      # (nil, or something validation will reject) are returned as given.
      #
      # @param value [Object]
      # @return [Object] a copy for a String or Array, value otherwise
      def self.secret(value)
        return value if value.is_a?(SecretString) || value.is_a?(SecretList)
        return SecretString.new(value) if value.is_a?(String)
        return SecretList.new(value.map { |item| secret(item) }) if value.is_a?(Array)

        value
      end

      # Per-fiber set of objects whose #inspect is running, so an object that
      # is reachable from its own instance variables prints as "...".
      IN_PROGRESS_KEY = :__otto_redacted_inspect_in_progress__
      private_constant :IN_PROGRESS_KEY

      # @return [String] "#<Class:0x... @ivar=value, ...>" with secret values
      #   replaced
      def inspect
        head        = Kernel.instance_method(:to_s).bind_call(self).delete_suffix('>')
        in_progress = (Thread.current[IN_PROGRESS_KEY] ||= {}.compare_by_identity)
        return "#{head} ...>" if in_progress.key?(self)

        in_progress[self] = true
        begin
          fields = instance_variables.map do |ivar|
            "#{ivar}=#{redacted_inspect_value(ivar, instance_variable_get(ivar))}"
          end
          fields.empty? ? "#{head}>" : "#{head} #{fields.join(', ')}>"
        ensure
          in_progress.delete(self)
        end
      end

      private

      # The text shown for one instance variable. Override to redact.
      #
      # @param _ivar [Symbol] instance variable name, e.g. :@secret
      # @param value [Object] its value
      # @return [String]
      def redacted_inspect_value(_ivar, value)
        value.inspect
      end

      # The placeholder for a secret value: nil stays "nil" so an unset secret
      # is still visible, and a collection shows how many values it holds.
      #
      # @param value [Object] the secret value
      # @return [String]
      def redacted_placeholder(value)
        return 'nil' if value.nil?
        return "#{PLACEHOLDER} (#{value.size})" if value.is_a?(Enumerable) && value.respond_to?(:size)

        PLACEHOLDER
      end
    end
  end
end
