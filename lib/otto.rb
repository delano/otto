require 'json'
require 'logger'
require 'ostruct'
require 'securerandom'
require 'uri'

require 'rack/request'
require 'rack/response'
require 'rack/utils'

require_relative 'otto/route_definition'
require_relative 'otto/route'
require_relative 'otto/static'
require_relative 'otto/helpers/request'
require_relative 'otto/helpers/response'
require_relative 'otto/response_handlers'
require_relative 'otto/version'
require_relative 'otto/security/config'
require_relative 'otto/security/csrf'
require_relative 'otto/security/validator'

# Otto is a simple Rack router that allows you to define routes in a file
# with built-in security features including CSRF protection, input validation,
# and trusted proxy support.
#
# Basic usage:
#   otto = Otto.new('routes.txt')
#
# With security features:
#   otto = Otto.new('routes.txt', {
#     csrf_protection: true,
#     request_validation: true,
#     trusted_proxies: ['10.0.0.0/8']
#   })
#
# Security headers are applied conservatively by default (only basic headers
# like X-Content-Type-Options). Restrictive headers like HSTS, CSP, and
# X-Frame-Options must be enabled explicitly:
#   otto.enable_hsts!
#   otto.enable_csp!
#   otto.enable_frame_protection!
#
class Otto
  LIB_HOME = __dir__ unless defined?(Otto::LIB_HOME)

  @debug  = ENV['OTTO_DEBUG'] == 'true'
  @logger = Logger.new($stdout, Logger::INFO)
  @global_config = {}

  # Global configuration for all Otto instances
  def self.configure
    config = OpenStruct.new(@global_config)
    yield config
    @global_config = config.to_h
  end

  def self.global_config
    @global_config
  end

  attr_reader :routes, :routes_literal, :routes_static, :route_definitions, :option, :static_route, :security_config, :locale_config
  attr_accessor :not_found, :server_error, :middleware_stack

  def initialize(path = nil, opts = {})
    @routes_static     = { GET: {} }
    @routes            = { GET: [] }
    @routes_literal    = { GET: {} }
    @route_definitions = {}
    @option            = {
      public: nil,
      locale: 'en',
    }.merge(opts)
    @security_config   = Otto::Security::Config.new
    @middleware_stack  = []

    # Configure locale support (merge global config with instance options)
    configure_locale(opts)

    # Configure security based on options
    configure_security(opts)

    Otto.logger.debug "new Otto: #{opts}" if Otto.debug
    load(path) unless path.nil?
    super()
  end
  alias options option

  def load(path)
    path = File.expand_path(path)
    raise ArgumentError, "Bad path: #{path}" unless File.exist?(path)

    raw = File.readlines(path).select { |line| line =~ /^\w/ }.collect { |line| line.strip }
    raw.each do |entry|
      # Enhanced parsing: split only on first two whitespace boundaries
      # This preserves parameters in the definition part
      parts = entry.split(/\s+/, 3)
      verb, path, definition = parts[0], parts[1], parts[2]
      route                                   = Otto::Route.new verb, path, definition
      route.otto                              = self
      path_clean                              = path.gsub(%r{/$}, '')
      @route_definitions[route.definition]    = route
      Otto.logger.debug "route: #{route.pattern}" if Otto.debug
      @routes[route.verb]                   ||= []
      @routes[route.verb] << route
      @routes_literal[route.verb]           ||= {}
      @routes_literal[route.verb][path_clean] = route
    rescue StandardError
      Otto.logger.error "Bad route in #{path}: #{entry}"
    end
    self
  end

  def safe_file?(path)
    return false if option[:public].nil? || option[:public].empty?
    return false if path.nil? || path.empty?

    # Normalize and resolve the public directory path
    public_dir = File.expand_path(option[:public])
    return false unless File.directory?(public_dir)

    # Clean the requested path - remove null bytes and normalize
    clean_path = path.delete("\0").strip
    return false if clean_path.empty?

    # Join and expand to get the full resolved path
    requested_path = File.expand_path(File.join(public_dir, clean_path))

    # Ensure the resolved path is within the public directory (prevents path traversal)
    return false unless requested_path.start_with?(public_dir + File::SEPARATOR)

    # Check file exists, is readable, and is not a directory
    File.exist?(requested_path) &&
      File.readable?(requested_path) &&
      !File.directory?(requested_path) &&
      (File.owned?(requested_path) || File.grpowned?(requested_path))
  end

  def safe_dir?(path)
    return false if path.nil? || path.empty?

    # Clean and expand the path
    clean_path = path.delete("\0").strip
    return false if clean_path.empty?

    expanded_path = File.expand_path(clean_path)

    # Check directory exists, is readable, and has proper ownership
    File.directory?(expanded_path) &&
      File.readable?(expanded_path) &&
      (File.owned?(expanded_path) || File.grpowned?(expanded_path))
  end

  def add_static_path(path)
    return unless safe_file?(path)

    base_path                      = File.split(path).first
    # Files in the root directory can refer to themselves
    base_path                      = path if base_path == '/'
    File.join(option[:public], base_path)
    Otto.logger.debug "new static route: #{base_path} (#{path})" if Otto.debug
    routes_static[:GET][base_path] = base_path
  end

  def call(env)
    # Apply middleware stack
    app = ->(e) { handle_request(e) }
    @middleware_stack.reverse_each do |middleware|
      app = middleware.new(app, @security_config)
    end

    begin
      app.call(env)
    rescue StandardError => ex
      handle_error(ex, env)
    end
  end

  def handle_request(env)
    locale             = determine_locale env
    env['rack.locale'] = locale
    env['otto.locale_config'] = @locale_config if @locale_config
    @static_route    ||= Rack::Files.new(option[:public]) if option[:public] && safe_dir?(option[:public])
    path_info          = Rack::Utils.unescape(env['PATH_INFO'])
    path_info          = '/' if path_info.to_s.empty?

    begin
      path_info_clean = path_info
        .encode(
          'UTF-8', # Target encoding
          invalid: :replace, # Replace invalid byte sequences
          undef: :replace,   # Replace characters undefined in UTF-8
          replace: '',        # Use empty string for replacement
        )
        .gsub(%r{/$}, '') # Remove trailing slash, if present
    rescue ArgumentError => ex
      # Log the error but don't expose details
      Otto.logger.error '[Otto.handle_request] Path encoding error'
      Otto.logger.debug "[Otto.handle_request] Error details: #{ex.message}" if Otto.debug
      # Set a default value or use the original path_info
      path_info_clean = path_info
    end

    base_path      = File.split(path_info).first
    # Files in the root directory can refer to themselves
    base_path      = path_info if base_path == '/'
    http_verb      = env['REQUEST_METHOD'].upcase.to_sym
    literal_routes = routes_literal[http_verb] || {}
    literal_routes.merge! routes_literal[:GET] if http_verb == :HEAD
    if static_route && http_verb == :GET && routes_static[:GET].member?(base_path)
      # Otto.logger.debug " request: #{path_info} (static)"
      static_route.call(env)
    elsif literal_routes.has_key?(path_info_clean)
      route = literal_routes[path_info_clean]
      # Otto.logger.debug " request: #{http_verb} #{path_info} (literal route: #{route.verb} #{route.path})"
      route.call(env)
    elsif static_route && http_verb == :GET && safe_file?(path_info)
      Otto.logger.debug " new static route: #{base_path} (#{path_info})" if Otto.debug
      routes_static[:GET][base_path] = base_path
      static_route.call(env)
    else
      extra_params  = {}
      found_route   = nil
      valid_routes  = routes[http_verb] || []
      valid_routes.push(*routes[:GET]) if http_verb == :HEAD
      valid_routes.each do |route|
        # Otto.logger.debug " request: #{http_verb} #{path_info} (trying route: #{route.verb} #{route.pattern})"
        next unless (match = route.pattern.match(path_info))

        values       = match.captures.to_a
        # The first capture returned is the entire matched string b/c
        # we wrapped the entire regex in parens. We don't need it to
        # the full match.
        values.shift
        extra_params =
          if route.keys.any?
            route.keys.zip(values).each_with_object({}) do |(k, v), hash|
              if k == 'splat'
                (hash[k] ||= []) << v
              else
                hash[k] = v
              end
            end
          elsif values.any?
            { 'captures' => values }
          else
            {}
          end
        found_route  = route
        break
      end
      found_route ||= literal_routes['/404']
      if found_route
        found_route.call env, extra_params
      else
        @not_found || Otto::Static.not_found
      end
    end
  end

  # Return the URI path for the given +route_definition+
  # e.g.
  #
  #     Otto.default.path 'YourClass.somemethod'  #=> /some/path
  #
  def uri(route_definition, params = {})
    # raise RuntimeError, "Not working"
    route = @route_definitions[route_definition]
    return if route.nil?

    local_params = params.clone
    local_path   = route.path.clone

    local_params.each_pair do |k, v|
      next unless local_path.match(":#{k}")

      local_path.gsub!(":#{k}", v.to_s)
      local_params.delete(k)
    end

    uri = URI::HTTP.new(nil, nil, nil, nil, nil, local_path, nil, nil, nil)
    unless local_params.empty?
      query_string = local_params.map { |k, v| "#{URI.encode_www_form_component(k)}=#{URI.encode_www_form_component(v)}" }.join('&')
      uri.query    = query_string
    end
    uri.to_s
  end

  def determine_locale(env)
    accept_langs = env['HTTP_ACCEPT_LANGUAGE']
    accept_langs = option[:locale] if accept_langs.to_s.empty?
    locales      = []
    unless accept_langs.empty?
      locales = accept_langs.split(',').map do |l|
        l += ';q=1.0' unless /;q=\d+(?:\.\d+)?$/.match?(l)
        l.split(';q=')
      end.sort_by do |_locale, qvalue|
        qvalue.to_f
      end.collect do |locale, _qvalue|
        locale
      end.reverse
    end
    Otto.logger.debug "locale: #{locales} (#{accept_langs})" if Otto.debug
    locales.empty? ? nil : locales
  end

  # Add middleware to the stack
  #
  # @param middleware [Class] The middleware class to add
  # @param args [Array] Additional arguments for the middleware
  # @param block [Proc] Optional block for middleware configuration
  def use(middleware, *, &)
    @middleware_stack << middleware
  end

  # Enable CSRF protection for POST, PUT, DELETE, and PATCH requests.
  # This will automatically add CSRF tokens to HTML forms and validate
  # them on unsafe HTTP methods.
  #
  # @example
  #   otto.enable_csrf_protection!
  def enable_csrf_protection!
    return if middleware_enabled?(Otto::Security::CSRFMiddleware)

    @security_config.enable_csrf_protection!
    use Otto::Security::CSRFMiddleware
  end

  # Enable request validation including input sanitization, size limits,
  # and protection against XSS and SQL injection attacks.
  #
  # @example
  #   otto.enable_request_validation!
  def enable_request_validation!
    return if middleware_enabled?(Otto::Security::ValidationMiddleware)

    @security_config.input_validation = true
    use Otto::Security::ValidationMiddleware
  end

  # Add a trusted proxy server for accurate client IP detection.
  # Only requests from trusted proxies will have their forwarded headers honored.
  #
  # @param proxy [String, Regexp] IP address, CIDR range, or regex pattern
  # @example
  #   otto.add_trusted_proxy('10.0.0.0/8')
  #   otto.add_trusted_proxy(/^172\.16\./)
  def add_trusted_proxy(proxy)
    @security_config.add_trusted_proxy(proxy)
  end

  # Set custom security headers that will be added to all responses.
  # These merge with the default security headers.
  #
  # @param headers [Hash] Hash of header name => value pairs
  # @example
  #   otto.set_security_headers({
  #     'content-security-policy' => "default-src 'self'",
  #     'strict-transport-security' => 'max-age=31536000'
  #   })
  def set_security_headers(headers)
    @security_config.security_headers.merge!(headers)
  end

  # Enable HTTP Strict Transport Security (HSTS) header.
  # WARNING: This can make your domain inaccessible if HTTPS is not properly
  # configured. Only enable this when you're certain HTTPS is working correctly.
  #
  # @param max_age [Integer] Maximum age in seconds (default: 1 year)
  # @param include_subdomains [Boolean] Apply to all subdomains (default: true)
  # @example
  #   otto.enable_hsts!(max_age: 86400, include_subdomains: false)
  def enable_hsts!(max_age: 31_536_000, include_subdomains: true)
    @security_config.enable_hsts!(max_age: max_age, include_subdomains: include_subdomains)
  end

  # Enable Content Security Policy (CSP) header to prevent XSS attacks.
  # The default policy only allows resources from the same origin.
  #
  # @param policy [String] CSP policy string (default: "default-src 'self'")
  # @example
  #   otto.enable_csp!("default-src 'self'; script-src 'self' 'unsafe-inline'")
  def enable_csp!(policy = "default-src 'self'")
    @security_config.enable_csp!(policy)
  end

  # Enable X-Frame-Options header to prevent clickjacking attacks.
  #
  # @param option [String] Frame options: 'DENY', 'SAMEORIGIN', or 'ALLOW-FROM uri'
  # @example
  #   otto.enable_frame_protection!('DENY')
  def enable_frame_protection!(option = 'SAMEORIGIN')
    @security_config.enable_frame_protection!(option)
  end

  # Enable Content Security Policy (CSP) with nonce support for dynamic header generation.
  # This enables the res.send_csp_headers response helper method.
  #
  # @param debug [Boolean] Enable debug logging for CSP headers (default: false)
  # @example
  #   otto.enable_csp_with_nonce!(debug: true)
  def enable_csp_with_nonce!(debug: false)
    @security_config.enable_csp_with_nonce!(debug: debug)
  end

  # Configure locale settings for the application
  #
  # @param available_locales [Hash] Hash of available locales (e.g., { 'en' => 'English', 'es' => 'Spanish' })
  # @param default_locale [String] Default locale to use as fallback
  # @example
  #   otto.configure(
  #     available_locales: { 'en' => 'English', 'es' => 'Spanish', 'fr' => 'French' },
  #     default_locale: 'en'
  #   )
  def configure(available_locales: nil, default_locale: nil)
    @locale_config ||= {}
    @locale_config[:available_locales] = available_locales if available_locales
    @locale_config[:default_locale] = default_locale if default_locale
  end

  private

  def configure_locale(opts)
    # Start with global configuration
    global_config = self.class.global_config
    @locale_config = nil

    # Check if we have any locale configuration from any source
    has_global_locale = global_config && (global_config[:available_locales] || global_config[:default_locale])
    has_direct_options = opts[:available_locales] || opts[:default_locale]
    has_legacy_config = opts[:locale_config]

    # Only create locale_config if we have configuration from somewhere
    if has_global_locale || has_direct_options || has_legacy_config
      @locale_config = {}

      # Apply global configuration first
      @locale_config[:available_locales] = global_config[:available_locales] if global_config && global_config[:available_locales]
      @locale_config[:default_locale] = global_config[:default_locale] if global_config && global_config[:default_locale]

      # Apply direct instance options (these override global config)
      @locale_config[:available_locales] = opts[:available_locales] if opts[:available_locales]
      @locale_config[:default_locale] = opts[:default_locale] if opts[:default_locale]

      # Legacy support: Configure locale if provided in initialization options via locale_config hash
      if opts[:locale_config]
        locale_opts = opts[:locale_config]
        @locale_config[:available_locales] = locale_opts[:available_locales] || locale_opts[:available] if locale_opts[:available_locales] || locale_opts[:available]
        @locale_config[:default_locale] = locale_opts[:default_locale] || locale_opts[:default] if locale_opts[:default_locale] || locale_opts[:default]
      end
    end
  end

  def configure_security(opts)
    # Enable CSRF protection if requested
    enable_csrf_protection! if opts[:csrf_protection]

    # Enable request validation if requested
    enable_request_validation! if opts[:request_validation]

    # Add trusted proxies if provided
    if opts[:trusted_proxies]
      Array(opts[:trusted_proxies]).each { |proxy| add_trusted_proxy(proxy) }
    end

    # Set custom security headers
    if opts[:security_headers]
      set_security_headers(opts[:security_headers])
    end
  end

  def middleware_enabled?(middleware_class)
    @middleware_stack.any? { |m| m == middleware_class }
  end

  def handle_error(error, env)
    # Log error details internally but don't expose them
    error_id = SecureRandom.hex(8)
    Otto.logger.error "[#{error_id}] #{error.class}: #{error.message}"
    Otto.logger.debug "[#{error_id}] Backtrace: #{error.backtrace.join("\n")}" if Otto.debug

    # Parse request for content negotiation
    begin
      Rack::Request.new(env)
    rescue StandardError
      nil
    end
    literal_routes = @routes_literal[:GET] || {}

    # Try custom 500 route first
    if found_route = literal_routes['/500']
      begin
        env['otto.error_id'] = error_id
        return found_route.call(env)
      rescue StandardError => ex
        Otto.logger.error "[#{error_id}] Error in custom error handler: #{ex.message}"
      end
    end

    # Content negotiation for built-in error response
    accept_header = env['HTTP_ACCEPT'].to_s
    if accept_header.include?('application/json')
      return json_error_response(error_id)
    end

    # Fallback to built-in error response
    @server_error || secure_error_response(error_id)
  end

  def secure_error_response(error_id)
    body = if Otto.env?(:dev, :development)
             "Server error (ID: #{error_id}). Check logs for details."
           else
             'An error occurred. Please try again later.'
           end

    headers = {
      'content-type' => 'text/plain',
      'content-length' => body.bytesize.to_s,
    }.merge(@security_config.security_headers)

    [500, headers, [body]]
  end

  def json_error_response(error_id)
    error_data = if Otto.env?(:dev, :development)
      {
        error: 'Internal Server Error',
        message: 'Server error occurred. Check logs for details.',
        error_id: error_id,
      }
    else
      {
        error: 'Internal Server Error',
        message: 'An error occurred. Please try again later.',
      }
    end

    body    = JSON.generate(error_data)
    headers = {
      'content-type' => 'application/json',
      'content-length' => body.bytesize.to_s,
    }.merge(@security_config.security_headers)

    [500, headers, [body]]
  end

  class << self
    attr_accessor :debug, :logger
  end

  module ClassMethods
    def default
      @default ||= Otto.new
      @default
    end

    def load(path)
      default.load path
    end

    def path(definition, params = {})
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
