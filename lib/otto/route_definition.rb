# lib/otto/route_definition.rb

class Otto
  # Immutable data class representing a complete route definition
  # This encapsulates all aspects of a route: path, target, and options
  class RouteDefinition
    # @return [String] The HTTP verb (GET, POST, etc.)
    attr_reader :verb

    # @return [String] The URL path pattern
    attr_reader :path

    # @return [String] The original definition string
    attr_reader :definition

    # @return [String] The target class and method (e.g., "TestApp.index")
    attr_reader :target

    # @return [String] The class name portion
    attr_reader :klass_name

    # @return [String] The method name portion
    attr_reader :method_name

    # @return [Symbol] The invocation kind (:class, :instance, or :logic)
    attr_reader :kind

    # @return [Hash] The route options (auth, response, csrf, etc.)
    attr_reader :options

    # @return [Regexp] The compiled path pattern for matching
    attr_reader :pattern

    # @return [Array<String>] The parameter keys extracted from the path
    attr_reader :keys

    def initialize(verb, path, definition, pattern: nil, keys: nil)
      @verb = verb.to_s.upcase.to_sym
      @path = path
      @definition = definition
      @pattern = pattern
      @keys = keys || []

      # Parse the definition into target and options
      parsed = parse_definition(definition)
      @target = parsed[:target]
      @options = parsed[:options].freeze

      # Parse the target into class, method, and kind
      target_parsed = parse_target(@target)
      @klass_name = target_parsed[:klass_name]
      @method_name = target_parsed[:method_name]
      @kind = target_parsed[:kind]

      # Freeze for immutability
      freeze
    end

    # Check if route has specific option
    # @param key [Symbol, String] Option key to check
    # @return [Boolean]
    def has_option?(key)
      @options.key?(key.to_sym)
    end

    # Get option value with optional default
    # @param key [Symbol, String] Option key
    # @param default [Object] Default value if option not present
    # @return [Object]
    def option(key, default = nil)
      @options.fetch(key.to_sym, default)
    end

    # Get authentication requirement
    # @return [String, nil] The auth requirement or nil
    def auth_requirement
      option(:auth)
    end

    # Get response type
    # @return [String] The response type (defaults to 'default')
    def response_type
      option(:response, 'default')
    end

    # Check if CSRF is exempt for this route
    # @return [Boolean]
    def csrf_exempt?
      option(:csrf) == 'exempt'
    end

    # Check if this is a Logic class route (no . or # in target)
    # @return [Boolean]
    def logic_route?
      kind == :logic
    end

    # Create a new RouteDefinition with modified options
    # @param new_options [Hash] Options to merge/override
    # @return [RouteDefinition] New immutable instance
    def with_options(new_options)
      merged_options = @options.merge(new_options)
      new_definition = [@target, *merged_options.map { |k, v| "#{k}=#{v}" }].join(' ')

      self.class.new(@verb, @path, new_definition, pattern: @pattern, keys: @keys)
    end

    # Convert to hash representation
    # @return [Hash]
    def to_h
      {
        verb: @verb,
        path: @path,
        definition: @definition,
        target: @target,
        klass_name: @klass_name,
        method_name: @method_name,
        kind: @kind,
        options: @options,
        pattern: @pattern,
        keys: @keys
      }
    end

    # String representation for debugging
    # @return [String]
    def to_s
      "#{@verb} #{@path} #{@definition}"
    end

    # Detailed inspection
    # @return [String]
    def inspect
      "#<Otto::RouteDefinition #{to_s} options=#{@options.inspect}>"
    end

    private

    # Parse route definition into target and options
    # @param definition [String] The route definition
    # @return [Hash] Hash with :target and :options keys
    def parse_definition(definition)
      parts = definition.split(/\s+/)
      target = parts.shift
      options = {}

      parts.each do |part|
        key, value = part.split('=', 2)
        if key && value
          options[key.to_sym] = value
        else
          # Malformed parameter, log warning if debug enabled
          Otto.logger.warn "Ignoring malformed route parameter: #{part}" if Otto.debug
        end
      end

      { target: target, options: options }
    end

    # Parse target into class name, method name, and kind
    # @param target [String] The target definition (e.g., "TestApp.index")
    # @return [Hash] Hash with :klass_name, :method_name, and :kind
    def parse_target(target)
      if target.include?('.')
        klass_name, method_name = target.split('.', 2)
        { klass_name: klass_name, method_name: method_name, kind: :class }
      elsif target.include?('#')
        klass_name, method_name = target.split('#', 2)
        { klass_name: klass_name, method_name: method_name, kind: :instance }
      elsif target.match?(/\A[A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*\z/)
        # Namespaced class with implicit method name (class method with same name as class)
        # E.g., "V2::Logic::Admin::Panel" -> Panel.Panel (class method)
        # For single word classes like "Logic", it's truly a logic class
        method_name = target.split('::').last
        if target.include?('::')
          # Namespaced class - treat as class method with implicit method name
          { klass_name: target, method_name: method_name, kind: :class }
        else
          # Single word class - treat as logic class
          { klass_name: target, method_name: method_name, kind: :logic }
        end
      else
        raise ArgumentError, "Invalid target format: #{target}"
      end
    end
  end
end
