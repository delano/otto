# lib/otto/core/freezable.rb

# lib/otto/core/freezable.rb

require 'set'

class Otto
  module Core
    # Provides deep freezing capability for configuration objects
    #
    # This module enables objects to be deeply frozen, preventing any
    # modifications to the object itself and all its nested structures.
    # This is critical for security as it prevents runtime tampering with
    # security configurations.
    #
    # @example
    #   class MyConfig
    #     include Otto::Core::Freezable
    #
    #     def initialize
    #       @settings = { security: { enabled: true } }
    #     end
    #   end
    #
    #   config = MyConfig.new
    #   config.deep_freeze!
    #   # Now config and all nested hashes/arrays are frozen
    #
    module Freezable
      # Deeply freeze this object and all its instance variables
      #
      # This method recursively freezes all nested structures including:
      # - Hashes (both keys and values)
      # - Arrays (and all elements)
      # - Sets
      # - Other freezable objects
      #
      # NOTE: This method is idempotent and safe to call multiple times.
      #
      # @return [self] The frozen object
      def deep_freeze!
        return self if frozen?

        freeze_instance_variables!
        freeze
        self
      end

      private

      # Freeze all instance variables recursively
      def freeze_instance_variables!
        instance_variables.each do |var|
          value = instance_variable_get(var)
          deep_freeze_value(value)
        end
      end

      # Recursively freeze a value based on its type
      #
      # @param value [Object] Value to freeze
      # @return [void]
      def deep_freeze_value(value)
        case value
        when Hash
          # Freeze hash keys and values, then freeze the hash itself
          value.each do |k, v|
            k.freeze unless k.frozen?
            deep_freeze_value(v)
          end
          value.freeze
        when Array
          # Freeze all array elements, then freeze the array
          value.each { |item| deep_freeze_value(item) }
          value.freeze
        when Set
          # Sets are immutable once frozen
          value.freeze
        when String, Symbol, Numeric, TrueClass, FalseClass, NilClass
          # These types are either immutable or already frozen
          value.freeze if value.respond_to?(:freeze) && !value.frozen?
        else
          # For other objects, recursively freeze if they support it, otherwise shallow freeze.
          if value.respond_to?(:deep_freeze!)
            value.deep_freeze!
          elsif value.respond_to?(:freeze) && !value.frozen?
            value.freeze
          end
        end
      end
    end
  end
end
