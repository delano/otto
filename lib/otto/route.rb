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
    module ClassMethods
      attr_accessor :otto
    end
    attr_reader :verb, :path, :pattern, :method, :klass, :name, :definition, :keys, :kind
    attr_accessor :otto

    # Initialize a new route with security validations
    #
    # @param verb [String] HTTP verb (GET, POST, PUT, DELETE, etc.)
    # @param path [String] URL path pattern with optional parameters
    # @param definition [String] Class and method definition (Class.method or Class#method)
    # @raise [ArgumentError] if definition format is invalid or class name is unsafe
    def initialize(verb, path, definition)
      @verb = verb.to_s.upcase.to_sym
      @path = path
      @definition = definition
      @pattern, @keys = *compile(@path)
      if !@definition.index('.').nil?
        @klass, @name = @definition.split('.')
        @kind = :class
      elsif !@definition.index('#').nil?
        @klass, @name = @definition.split('#')
        @kind = :instance
      else
        raise ArgumentError, "Bad definition: #{@definition}"
      end
      @klass = safe_const_get(@klass)
      # @method = @klass.method(@name)
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
        Object.const_get(class_name)
      rescue NameError => e
        raise ArgumentError, "Class not found: #{class_name} - #{e.message}"
      end
    end

    public

    def pattern_regexp
      Regexp.new(@path.gsub('/*', '/.+'))
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
      req = Rack::Request.new(env)
      res = Rack::Response.new
      req.extend Otto::RequestHelpers
      res.extend Otto::ResponseHelpers
      res.request = req
      
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

      case kind
      when :instance
        inst = klass.new req, res
        inst.send(name)
      when :class
        klass.send(name, req, res)
      else
        raise "Unsupported kind for #{@definition}: #{kind}"
      end
      res.body = [res.body] unless res.body.respond_to?(:each)
      res.finish
    end

    private

    # Brazenly borrowed from Sinatra::Base:
    # https://github.com/sinatra/sinatra/blob/v1.2.6/lib/sinatra/base.rb#L1156
    def compile(path)
      keys = []
      if path.respond_to? :to_str
        special_chars = %w[. + ( ) $]
        pattern =
          path.to_str.gsub(/((:\w+)|[\*#{special_chars.join}])/) do |match|
            case match
            when '*'
              keys << 'splat'
              '(.*?)'
            when *special_chars
              Regexp.escape(match)
            else
              keys << ::Regexp.last_match(2)[1..-1]
              '([^/?#]+)'
            end
          end
        # Wrap the regex in parens so the regex works properly.
        # They can fail when there's an | for example (matching only the last one).
        # Note: this means we also need to remove the first matched value.
        [/\A(#{pattern})\z/, keys]
      elsif path.respond_to?(:keys) && path.respond_to?(:match)
        [path, path.keys]
      elsif path.respond_to?(:names) && path.respond_to?(:match)
        [path, path.names]
      elsif path.respond_to? :match
        [path, keys]
      else
        raise TypeError, path
      end
    end
  end
end
