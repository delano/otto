require 'logger'

require 'rack/request'
require 'rack/response'
require 'rack/utils'
require 'addressable/uri'

require_relative 'otto/route'
require_relative 'otto/static'
require_relative 'otto/helpers/request'
require_relative 'otto/helpers/response'
require_relative 'otto/version'

# Otto is a simple Rack router that allows you to define routes in a file
#
#
class Otto
  LIB_HOME = __dir__ unless defined?(Otto::LIB_HOME)

  @debug = ENV['OTTO_DEBUG'] == 'true'
  @logger = Logger.new($stdout, Logger::INFO)

  attr_reader :routes, :routes_literal, :routes_static, :route_definitions
  attr_reader :option, :static_route
  attr_accessor :not_found, :server_error

  def initialize path=nil, opts={}
    @routes_static =  { GET: {} }
    @routes =         { GET: [] }
    @routes_literal = { GET: {} }
    @route_definitions = {}
    @option = opts.merge({
      public: nil,
      locale: 'en'
    })
    Otto.logger.debug "new Otto: #{opts}" if Otto.debug
    load(path) unless path.nil?
    super()
  end
  alias_method :options, :option

  def load path
    path = File.expand_path(path)
    raise ArgumentError, "Bad path: #{path}" unless File.exist?(path)
    raw = File.readlines(path).select { |line| line =~ /^\w/ }.collect { |line| line.strip.split(/\s+/) }
    raw.each { |entry|
      begin
        verb, path, definition = *entry
        route = Otto::Route.new verb, path, definition
        route.otto = self
        path_clean = path.gsub /\/$/, ''
        @route_definitions[route.definition] = route
        Otto.logger.debug "route: #{route.pattern}" if Otto.debug
        @routes[route.verb] ||= []
        @routes[route.verb] << route
        @routes_literal[route.verb] ||= {}
        @routes_literal[route.verb][path_clean] = route

      rescue StandardError => ex
        Otto.logger.error "Bad route in #{path}: #{entry}"
      end
    }
    self
  end

  def safe_file? path
    globstr = File.join(option[:public], '*')
    pathstr = File.join(option[:public], path)
    File.fnmatch?(globstr, pathstr) && (File.owned?(pathstr) || File.grpowned?(pathstr)) && File.readable?(pathstr) && !File.directory?(pathstr)
  end

  def safe_dir? path
    (File.owned?(path) || File.grpowned?(path)) && File.directory?(path)
  end

  def add_static_path path
    if safe_file?(path)
      base_path = File.split(path).first
      # Files in the root directory can refer to themselves
      base_path = path if base_path == '/'
      static_path = File.join(option[:public], base_path)
      Otto.logger.debug "new static route: #{base_path} (#{path})" if Otto.debug
      routes_static[:GET][base_path] = base_path
    end
  end

  def call env
    locale = determine_locale env
    env['rack.locale'] = locale
    if option[:public] && safe_dir?(option[:public])
      @static_route ||= Rack::File.new(option[:public])
    end
    path_info = Rack::Utils.unescape(env['PATH_INFO'])
    path_info = '/' if path_info.to_s.empty?

    begin
      path_info_clean = path_info
        .encode(
          'UTF-8',           # Target encoding
          invalid: :replace, # Replace invalid byte sequences
          undef: :replace,   # Replace characters undefined in UTF-8
          replace: ''        # Use empty string for replacement
        )
        .gsub(/\/$/, '')     # Remove trailing slash, if present
    rescue ArgumentError => ex
      # Log the error
      Otto.logger.error "[Otto.call] Error cleaning `#{path_info}`: #{ex.message}"
      # Set a default value or use the original path_info
      path_info_clean = path_info
    end

    base_path = File.split(path_info).first
    # Files in the root directory can refer to themselves
    base_path = path_info if base_path == '/'
    http_verb = env['REQUEST_METHOD'].upcase.to_sym
    literal_routes = routes_literal[http_verb] || {}
    literal_routes.merge! routes_literal[:GET] if http_verb == :HEAD
    if static_route && http_verb == :GET && routes_static[:GET].member?(base_path)
      #Otto.logger.debug " request: #{path_info} (static)"
      static_route.call(env)
    elsif literal_routes.has_key?(path_info_clean)
      route = literal_routes[path_info_clean]
      #Otto.logger.debug " request: #{http_verb} #{path_info} (literal route: #{route.verb} #{route.path})"
      route.call(env)
    elsif static_route && http_verb == :GET && safe_file?(path_info)
      static_path = File.join(option[:public], base_path)
      Otto.logger.debug " new static route: #{base_path} (#{path_info})"
      routes_static[:GET][base_path] = base_path
      static_route.call(env)
    else
      extra_params = {}
      found_route = nil
      valid_routes = routes[http_verb] || []
      valid_routes.push *routes[:GET] if http_verb == :HEAD
      valid_routes.each { |route|
        #Otto.logger.debug " request: #{http_verb} #{path_info} (trying route: #{route.verb} #{route.pattern})"
        if (match = route.pattern.match(path_info))
          values = match.captures.to_a
          # The first capture returned is the entire matched string b/c
          # we wrapped the entire regex in parens. We don't need it to
          # the full match.
          full_match = values.shift
          extra_params =
            if route.keys.any?
              route.keys.zip(values).inject({}) do |hash,(k,v)|
                if k == 'splat'
                  (hash[k] ||= []) << v
                else
                  hash[k] = v
                end
                hash
              end
            elsif values.any?
              {'captures' => values}
            else
              {}
            end
            found_route = route
            break
        end
      }
      found_route ||= literal_routes['/404']
      if found_route
        found_route.call env, extra_params
      else
        @not_found || Otto::Static.not_found
      end
    end
  rescue => ex
    Otto.logger.error "#{ex.class}: #{ex.message} #{ex.backtrace.join("\n")}"

    if found_route = literal_routes['/500']
      found_route.call env
    else
      @server_error || Otto::Static.server_error
    end
  end

  # Return the URI path for the given +route_definition+
  # e.g.
  #
  #     Otto.default.path 'YourClass.somemethod'  #=> /some/path
  #
  def uri route_definition, params={}
    #raise RuntimeError, "Not working"
    route = @route_definitions[route_definition]
    unless route.nil?
      local_params = params.clone
      local_path = route.path.clone
      if objid = local_params.delete(:id) || local_params.delete('id')
        local_path.gsub! /\*/, objid
      end
      local_params.each_pair { |k,v|
        next unless local_path.match(":#{k}")
        local_path.gsub!(":#{k}", local_params.delete(k))
      }
      uri = Addressable::URI.new
      uri.path = local_path
      uri.query_values = local_params
      uri.to_s
    end
  end

  def determine_locale env
    accept_langs = env['HTTP_ACCEPT_LANGUAGE']
    accept_langs = self.option[:locale] if accept_langs.to_s.empty?
    locales = []
    unless accept_langs.empty?
      locales = accept_langs.split(',').map { |l|
        l += ';q=1.0' unless l =~ /;q=\d+(?:\.\d+)?$/
        l.split(';q=')
      }.sort_by { |locale, qvalue|
        qvalue.to_f
      }.collect { |locale, qvalue|
        locale
      }.reverse
    end
    Otto.logger.debug "locale: #{locales} (#{accept_langs})" if Otto.debug
    locales.empty? ? nil : locales
  end

  class << self
    attr_accessor :debug, :logger
  end

  module ClassMethods
    def default
      @default ||= Otto.new
      @default
    end
    def load path
      default.load path
    end
    def path definition, params={}
      default.path definition, params
    end
    def routes
      default.routes
    end
    def env? *guesses
      !guesses.flatten.select { |n| ENV['RACK_ENV'].to_s == n.to_s }.empty?
    end
  end
  extend ClassMethods
end
