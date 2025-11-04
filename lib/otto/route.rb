# frozen_string_literal: true

# lib/otto/route.rb

class Otto
  # Otto::Route
  #
  # A Route is a definition of a URL path and the method to call when
  # that path is requested. Each route represents a single line in a
  # routes file.
  #
  # Routes include built-in security features:
  # - Class name validation to prevent code injection
  # - Automatic security header injection
  # - CSRF protection when enabled
  # - Input validation and sanitization
  #
  # e.g.
  #
  #      GET   /uri/path      YourApp.method
  #      GET   /uri/path2     YourApp#method
  #
  #
  class Route
    # Class methods for Route providing Otto instance access
    module ClassMethods
      attr_accessor :otto
    end
    # @return [Otto::RouteDefinition] The immutable route definition
    attr_reader :route_definition

    # @return [Class] The resolved class object
    attr_reader :klass

    attr_accessor :otto

    # Initialize a new route with security validations
    #
    # @param verb [String] HTTP verb (GET, POST, PUT, DELETE, etc.)
    # @param path [String] URL path pattern with optional parameters
    # @param definition [String] Class and method definition with optional key-value parameters
    #   Examples:
    #     "Class.method" (traditional)
    #     "Class#method" (traditional)
    #     "V2::Logic::AuthSession auth=authenticated response=redirect" (enhanced)
    # @raise [ArgumentError] if definition format is invalid or class name is unsafe
    def initialize(verb, path, definition)
      pattern, keys = *compile(path)

      # Create immutable route definition
      @route_definition = Otto::RouteDefinition.new(verb, path, definition, pattern: pattern, keys: keys)

      # Resolve the class
      @klass = safe_const_get(@route_definition.klass_name)
    end

    # Delegate common methods to route_definition for backward compatibility
    def verb
      @route_definition.verb
    end

    def path
      @route_definition.path
    end

    def definition
      @route_definition.definition
    end

    def pattern
      @route_definition.pattern
    end

    def keys
      @route_definition.keys
    end

    def name
      @route_definition.method_name
    end

    def kind
      @route_definition.kind
    end

    def route_options
      @route_definition.options
    end

    # Execute the route by calling the associated class method
    #
    # This method handles the complete request/response cycle with built-in security:
    # - Processes parameters through the security layer
    # - Adds configured security headers to the response
    # - Extends request/response with security helpers when enabled
    # - Provides CSRF and validation helpers to the target class
    #
    # @param env [Hash] Rack environment hash
    # @param extra_params [Hash] Additional parameters to merge (default: {})
    # @return [Array] Rack response array [status, headers, body]
    def call(env, extra_params = {})
      extra_params ||= {}
      req            = Rack::Request.new(env)
      res            = Rack::Response.new
      req.extend Otto::RequestHelpers
      res.extend Otto::ResponseHelpers
      res.request = req

      # Make security config available to response helpers
      env['otto.security_config'] = otto.security_config if otto.respond_to?(:security_config) && otto.security_config

      # NEW: Make route definition and options available to middleware and handlers
      env['otto.route_definition'] = @route_definition
      env['otto.route_options'] = @route_definition.options

      # Process parameters through security layer
      req.params.merge! extra_params
      req.params.replace Otto::Static.indifferent_params(req.params)

      # Add security headers
      if otto.respond_to?(:security_config) && otto.security_config
        otto.security_config.security_headers.each do |header, value|
          res.headers[header] = value
        end
      end

      klass.extend Otto::Route::ClassMethods
      klass.otto = otto

      # Add security helpers if CSRF is enabled
      if otto.respond_to?(:security_config) && otto.security_config&.csrf_enabled?
        res.extend Otto::Security::CSRFHelpers
      end

      # Add validation helpers
      res.extend Otto::Security::ValidationHelpers

      # NEW: Use the pluggable route handler factory (Phase 4)
      # This replaces the hardcoded execution pattern with a factory approach
      if otto&.route_handler_factory
        handler = otto.route_handler_factory.create_handler(@route_definition, otto)
        handler.call(env, extra_params)
      else
        # Fallback to legacy behavior for backward compatibility
        inst = nil
        result = case kind
                 when :instance
                   inst = klass.new req, res
                   inst.send(name)
                 when :class
                   klass.send(name, req, res)
                 else
                   raise "Unsupported kind for #{definition}: #{kind}"
                 end

        # Handle response based on route options
        response_type = @route_definition.response_type
        if response_type != 'default'
          context = {
            logic_instance: (kind == :instance ? inst : nil),
               status_code: nil,
             redirect_path: nil,
          }

          Otto::ResponseHandlers::HandlerFactory.handle_response(result, res, response_type, context)
        end

        res.body = [res.body] unless res.body.respond_to?(:each)
        res.finish
      end
    end

    private

    # Safely resolve a class name using Object.const_get with security validations
    # This replaces the previous eval() usage to prevent code injection attacks.
    #
    # Security features:
    # - Validates class name format (must start with capital letter)
    # - Prevents access to dangerous system classes
    # - Blocks relative class references (starting with ::)
    # - Provides clear error messages for debugging
    #
    # @param class_name [String] The class name to resolve
    # @return [Class] The resolved class
    # @raise [ArgumentError] if class name is invalid, forbidden, or not found
    def safe_const_get(class_name)
      # Validate class name format
      unless class_name.match?(/\A[A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*\z/)
        raise ArgumentError, "Invalid class name format: #{class_name}"
      end

      # Remove any leading :: then add exactly one
      fq_class_name = "::#{class_name.sub(/^::+/, '')}"

      # Prevent dangerous class names
      forbidden_classes = %w[
        Kernel Module Class Object BasicObject
        File Dir IO Process System
        Binding Proc Method UnboundMethod
        Thread ThreadGroup Fiber
        ObjectSpace GC
      ]

      if forbidden_classes.include?(class_name) || class_name.start_with?('::')
        raise ArgumentError, "Forbidden class name: #{class_name}"
      end

      begin
        # Always guarantee exactly two leading colons
        Object.const_get(fq_class_name)
      rescue NameError => e
        raise ArgumentError, "Class not found: #{fq_class_name} - #{e.message}"
      end
    end

    def compile(path)
      keys = []

      # Handle string paths first (most common case)
      if path.respond_to?(:to_str)
        compile_string_path(path, keys)
      else
        case path
        in { keys: route_keys, match: _ }
          [path, route_keys]
        in { names: route_names, match: _ }
          [path, route_names]
        in { match: _ }
          [path, keys]
        else
          raise TypeError, path
        end
      end
    end

    def compile_string_path(path, keys)
      raise TypeError, path unless path.respond_to?(:to_str)

      pattern = path.to_str.gsub(/((:\w+)|[.*+()$])/) do |match|
        case match
        when '*'
          keys << 'splat'
          '(.*?)'
        when '.', '+', '(', ')', '$'
          Regexp.escape(match)
        else
          keys << match[1..-1] # Remove the colon
          '([^/?#]+)'
        end
      end

      [/\A(#{pattern})\z/, keys]
    end
  end
end
