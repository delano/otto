# lib/otto/security/constant_resolver.rb
#
# frozen_string_literal: true

class Otto
  module Security
    # Shared, validated resolution of a class from its String name.
    #
    # Centralizes the class-name format check and the forbidden-class blocklist
    # so every dispatch path that turns a route/handler string into a constant
    # (Otto::Route, RouteHandlers::BaseHandler, and the MCP registry/server)
    # enforces the SAME guards against code-injection via crafted class names.
    module ConstantResolver
      # A class name is a sequence of ::-separated, capitalized Ruby constant
      # tokens. This also rejects leading "::" (a name must start with [A-Z]).
      CLASS_NAME_PATTERN = /\A[A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*\z/

      # Constants that must never be resolvable from untrusted route/handler
      # strings, since dispatching to them enables arbitrary/dangerous behavior.
      FORBIDDEN_CLASSES = %w[
        Kernel Module Class Object BasicObject
        File Dir IO Process System
        Binding Proc Method UnboundMethod
        Thread ThreadGroup Fiber
        ObjectSpace GC
      ].freeze

      # The actual constant objects behind FORBIDDEN_CLASSES that exist in this
      # runtime. The resolved constant is checked against these by identity so a
      # forbidden class reached through a namespace prefix (e.g. "Object::Kernel")
      # or via Ruby's trailing-segment constant inheritance (e.g. "App::File"
      # falling back to top-level ::File) is rejected even though its literal
      # string is not listed in FORBIDDEN_CLASSES. An app's OWN class that merely
      # shares a name (a distinct object) is unaffected.
      FORBIDDEN_CONSTANTS = FORBIDDEN_CLASSES.filter_map do |const_name|
        Object.const_get(const_name) if Object.const_defined?(const_name, false)
      end.freeze

      module_function

      # Resolve a validated class name to its Class object.
      #
      # @param class_name [String] fully-qualified class name (e.g. "App::Users")
      # @return [Class, Module] the resolved constant
      # @raise [ArgumentError] if the name is malformed, forbidden, or not found
      def safe_const_get(class_name)
        name = class_name.to_s

        raise ArgumentError, "Invalid class name format: #{class_name}" unless name.match?(CLASS_NAME_PATTERN)

        raise ArgumentError, "Forbidden class name: #{class_name}" if FORBIDDEN_CLASSES.include?(name)

        fq_class_name = "::#{name.sub(/^::+/, '')}"

        resolved =
          begin
            Object.const_get(fq_class_name)
          rescue NameError => e
            raise ArgumentError, "Class not found: #{fq_class_name} - #{e.message}"
          end

        # Reject forbidden constants reached via a namespace prefix or Ruby's
        # trailing-segment constant inheritance, which the literal-name check
        # above cannot see (e.g. "Object::Kernel", or "App::File" -> ::File).
        if FORBIDDEN_CONSTANTS.any? { |forbidden| resolved.equal?(forbidden) }
          raise ArgumentError, "Forbidden class name: #{class_name}"
        end

        resolved
      end
    end
  end
end
