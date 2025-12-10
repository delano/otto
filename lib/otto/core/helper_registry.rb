# lib/otto/core/helper_registry.rb
#
# frozen_string_literal: true

class Otto
  module Core
    # Helper registration module for extending Otto's Request and Response classes.
    # Provides the public API for registering custom helper modules.
    module HelperRegistry
      # Register request helper modules
      #
      # Registered modules are included in Otto::Request at the class level,
      # making custom helpers available alongside Otto's built-in helpers.
      # Must be called before first request (before configuration freezing).
      #
      # This is the official integration point for application-specific helpers
      # that work with Otto internals (strategy_result, privacy features, etc.).
      #
      # @param modules [Module, Array<Module>] Module(s) containing helper methods
      # @example
      #   module Onetime::RequestHelpers
      #     def current_customer
      #       user.is_a?(Onetime::Customer) ? user : Onetime::Customer.anonymous
      #     end
      #
      #     def organization
      #       @organization ||= strategy_result&.metadata.dig(:organization_context, :organization)
      #     end
      #   end
      #
      #   otto.register_request_helpers(Onetime::RequestHelpers)
      #
      # @raise [ArgumentError] if module is not a Module
      # @raise [FrozenError] if called after configuration is frozen
      def register_request_helpers(*modules)
        begin
          ensure_not_frozen!
        rescue FrozenError
          raise FrozenError, 'Cannot register request helpers after first request'
        end

        modules.each do |mod|
          unless mod.is_a?(Module)
            raise ArgumentError, "Expected Module, got #{mod.class}"
          end
          @request_helper_modules << mod unless @request_helper_modules.include?(mod)
        end

        # Re-finalize to include newly registered helpers
        finalize_request_response_classes
      end

      # Register response helper modules
      #
      # Registered modules are included in Otto::Response at the class level,
      # making custom helpers available alongside Otto's built-in helpers.
      # Must be called before first request (before configuration freezing).
      #
      # @param modules [Module, Array<Module>] Module(s) containing helper methods
      # @example
      #   module Onetime::ResponseHelpers
      #     def json_success(data, status: 200)
      #       headers['content-type'] = 'application/json'
      #       self.status = status
      #       write JSON.generate({ success: true, data: data })
      #     end
      #   end
      #
      #   otto.register_response_helpers(Onetime::ResponseHelpers)
      #
      # @raise [ArgumentError] if module is not a Module
      # @raise [FrozenError] if called after configuration is frozen
      def register_response_helpers(*modules)
        begin
          ensure_not_frozen!
        rescue FrozenError
          raise FrozenError, 'Cannot register response helpers after first request'
        end

        modules.each do |mod|
          unless mod.is_a?(Module)
            raise ArgumentError, "Expected Module, got #{mod.class}"
          end
          @response_helper_modules << mod unless @response_helper_modules.include?(mod)
        end

        # Re-finalize to include newly registered helpers
        finalize_request_response_classes
      end

      # Get registered request helper modules (for debugging)
      #
      # @return [Array<Module>] Array of registered request helper modules
      # @api private
      def registered_request_helpers
        @request_helper_modules.dup
      end

      # Get registered response helper modules (for debugging)
      #
      # @return [Array<Module>] Array of registered response helper modules
      # @api private
      def registered_response_helpers
        @response_helper_modules.dup
      end

      private

      # Finalize request and response classes with framework and custom helpers
      #
      # This method creates Otto's request and response classes by:
      # 1. Subclassing Otto::Request/Response (which have framework helpers built-in)
      # 2. Including any registered custom helper modules
      #
      # Called during initialization and can be called again if helpers are registered
      # after initialization (before first request).
      #
      # @return [void]
      # @api private
      def finalize_request_response_classes
        # Create request class with framework helpers
        # Otto::Request has all framework helpers as instance methods
        @request_class = Class.new(Otto::Request)

        # Create response class with framework helpers
        # Otto::Response has all framework helpers as instance methods
        @response_class = Class.new(Otto::Response)

        # Apply registered custom helpers (framework helpers always come first)
        @request_helper_modules&.each { |mod| @request_class.include(mod) }
        @response_helper_modules&.each { |mod| @response_class.include(mod) }
      end
    end
  end
end
