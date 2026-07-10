# lib/otto/route.rb
#
# frozen_string_literal: true

require_relative 'security/constant_resolver'

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

      # Resolve the class.
      # Lambda routes carry a registry KEY in klass_name, not a Ruby constant.
      # Skip constant resolution (it would raise on a lowercase/unregistered key
      # and the loader would silently drop the route).
      @klass = if @route_definition.kind == :lambda
                 nil
               else
                 Otto::Security::ConstantResolver.safe_const_get(@route_definition.klass_name)
               end
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

      # Pluggable route handler factory (Phase 4). The handler owns
      # request/response construction and decoration — param merging,
      # indifferent access, security headers, CSRF/validation helpers all
      # happen once in BaseHandler#setup_request_response. Building them here
      # too would duplicate that work on objects that get discarded (issue #189).
      if otto&.route_handler_factory
        # Make security config, route definition, and options available to
        # middleware and handlers before delegating, so wrappers that run
        # ahead of the handler's own setup (RouteAuthWrapper, the centralized
        # error handler) can see them.
        env['otto.security_config'] = otto.security_config if otto.respond_to?(:security_config) && otto.security_config
        env['otto.route_definition'] = @route_definition
        env['otto.route_options'] = @route_definition.options

        handler = otto.route_handler_factory.create_handler(@route_definition, otto)
        return handler.call(env, extra_params)
      end

      # Fallback to legacy behavior for backward compatibility. Build req/res
      # before touching env, preserving the exact ordering this path always
      # had — a custom request_class/response_class#initialize that reads env
      # must keep seeing it unpopulated, same as before #189 (review follow-up).
      req         = otto.request_class.new(env)
      res         = otto.response_class.new
      res.request = req

      # Make security config available to response helpers
      env['otto.security_config'] = otto.security_config if otto.respond_to?(:security_config) && otto.security_config

      # Make route definition and options available to middleware and handlers
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

      # No target class for lambda routes (klass is nil); skip class extension.
      if klass
        klass.extend Otto::Route::ClassMethods
        klass.otto = otto
      end

      # Add security helpers if CSRF is enabled
      if otto.respond_to?(:security_config) && otto.security_config&.csrf_enabled?
        res.extend Otto::Security::CSRFHelpers
      end

      # Add validation helpers
      res.extend Otto::Security::ValidationHelpers

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

    private

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
