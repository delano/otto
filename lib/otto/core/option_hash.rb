# lib/otto/core/option_hash.rb
#
# frozen_string_literal: true

require_relative 'redacted_inspect'

class Otto
  module Core
    # The Hash behind Otto#option. freeze_configuration! deep-freezes it, and
    # Ruby's FrozenError message embeds #inspect of the frozen receiver, so a
    # late write such as otto.option[:x] = 1 would print every option,
    # including the MCP bearer tokens.
    #
    # .build and every Hash method that can store a value under a key (#[]=,
    # #store, #merge!, #update, #replace, #transform_values!,
    # #transform_keys!) store the values of .secret_keys as RedactedInspect
    # secrets (a SecretList or SecretSet of SecretStrings, or a
    # SecretString), so a write to the frozen token collection or to one
    # token cannot print them either. #inspect also redacts those keys
    # whatever their value. It is still a Hash, and the token values are
    # still an Array, a Set or a String.
    class OptionHash < Hash
      # Option keys whose values are MCP bearer tokens, in both spellings a
      # caller may use (see Otto::MCP::Options::OPTION_ALIASES).
      def self.secret_keys
        @secret_keys ||= Otto::MCP::Options::OPTION_ALIASES.fetch(:auth_tokens).flat_map do |key|
          [key, key.to_s]
        end.freeze
      end

      # @param hash [Hash] assembled options
      # @return [OptionHash] a copy with secret values wrapped
      def self.build(hash)
        hash.each_with_object(new) do |(key, value), options|
          options[key] = value
        end
      end

      # Stores value, wrapped by RedactedInspect.secret when key is one of
      # .secret_keys, so a token assigned after construction is covered too.
      def []=(key, value)
        super(key, self.class.secret_keys.include?(key) ? RedactedInspect.secret(value) : value)
      end
      alias store []=

      # The other Hash methods that can put a value under a key are written in
      # C and do not call #[]=, so each wraps the secret keys after it runs.
      # (default= and default_proc= set no entry.)

      # @return [self]
      def merge!(...)
        super
        wrap_secret_values!
      end
      alias update merge!

      # @return [self]
      def replace(...)
        super
        wrap_secret_values!
      end

      # @return [self]
      def transform_values!(...)
        result = super
        wrap_secret_values!
        result
      end

      # @return [self]
      def transform_keys!(...)
        result = super
        wrap_secret_values!
        result
      end

      # @return [String] Hash#inspect with each secret key's value redacted
      def inspect
        redacted_view.inspect
      end
      alias to_s inspect

      # Hash#pretty_print walks the pairs itself instead of calling #inspect.
      #
      # @param printer [PP]
      def pretty_print(printer)
        printer.pp(redacted_view)
      end

      private

      # Re-store each secret key's value through #[]=, which wraps it.
      def wrap_secret_values!
        self.class.secret_keys.each do |key|
          self[key] = fetch(key) if key?(key)
        end
        self
      end

      # A plain Hash copy with each secret key's value replaced.
      def redacted_view
        to_h do |key, value|
          [key, self.class.secret_keys.include?(key) ? Placeholder.new(value) : value]
        end
      end

      # Prints the redaction placeholder for a secret value from #inspect and
      # from pp.
      Placeholder = Struct.new(:value) do
        def inspect
          return 'nil' if value.nil?
          return "#{RedactedInspect::PLACEHOLDER} (#{value.size})" if value.is_a?(Enumerable) && !value.is_a?(Hash)

          RedactedInspect::PLACEHOLDER
        end

        def pretty_print(printer)
          printer.text(inspect)
        end
      end
      private_constant :Placeholder
    end
  end
end
