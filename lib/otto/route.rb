# lib/otto/route.rb

class Otto
  # Otto::Route
  #
  # A Route is a definition of a URL path and the method to call when
  # that path is requested. Each route represents a single line in a
  # routes file.
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
      @klass = eval(@klass)
      # @method = eval(@klass).method(@name)
    end

    def pattern_regexp
      Regexp.new(@path.gsub('/*', '/.+'))
    end

    def call(env, extra_params = {})
      extra_params ||= {}
      req = Rack::Request.new(env)
      res = Rack::Response.new
      req.extend Otto::RequestHelpers
      res.extend Otto::ResponseHelpers
      res.request = req
      req.params.merge! extra_params
      req.params.replace Otto::Static.indifferent_params(req.params)
      klass.extend Otto::Route::ClassMethods
      klass.otto = otto

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
