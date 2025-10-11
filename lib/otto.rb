# frozen_string_literal: true

# lib/otto.rb

require 'json'
require 'logger'
require 'securerandom'
require 'uri'

require 'rack/request'
require 'rack/response'
require 'rack/utils'

require_relative 'otto/security/authentication/strategy_result'
require_relative 'otto/route_definition'
require_relative 'otto/route'
require_relative 'otto/static'
require_relative 'otto/helpers/request'
require_relative 'otto/helpers/response'
require_relative 'otto/response_handlers'
require_relative 'otto/route_handlers'
require_relative 'otto/version'
require_relative 'otto/security/config'
require_relative 'otto/security/middleware/csrf_middleware'
require_relative 'otto/security/middleware/validation_middleware'
require_relative 'otto/security/authentication/authentication_middleware'
require_relative 'otto/security/middleware/rate_limit_middleware'
require_relative 'otto/mcp/server'
require_relative 'otto/core/router'
require_relative 'otto/core/file_safety'
require_relative 'otto/core/configuration'
require_relative 'otto/core/error_handler'
require_relative 'otto/core/uri_generator'
require_relative 'otto/core/middleware_stack'
require_relative 'otto/security/configurator'
require_relative 'otto/utils'

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
# Configuration Data class to replace OpenStruct
# Configuration class to replace OpenStruct
class ConfigData
  def initialize(**kwargs)
    @data = kwargs
  end

  # Dynamic attribute accessors
  def method_missing(method_name, *args)
    if method_name.to_s.end_with?('=')
      # Setter
      attr_name = method_name.to_s.chomp('=').to_sym
      @data[attr_name] = args.first
    elsif @data.key?(method_name)
      # Getter
      @data[method_name]
    else
      super
    end
  end

  def respond_to_missing?(method_name, include_private = false)
    method_name.to_s.end_with?('=') || @data.key?(method_name) || super
  end

  # Convert to hash for compatibility
  def to_h
    @data.dup
  end
end

class Otto
  include Otto::Core::Router
  include Otto::Core::FileSafety
  include Otto::Core::Configuration
  include Otto::Core::ErrorHandler
  include Otto::Core::UriGenerator

  LIB_HOME = __dir__ unless defined?(Otto::LIB_HOME)

  @debug = case ENV.fetch('OTTO_DEBUG', nil)
           in 'true' | '1' | 'yes' | 'on'
             true
           else
             defined?(Otto::Utils) ? Otto::Utils.yes?(ENV.fetch('OTTO_DEBUG', nil)) : false
           end
  @logger        = Logger.new($stdout, Logger::INFO)
  @global_config = nil

  # Global configuration for all Otto instances (Ruby 3.2+ pattern matching)
  def self.configure
    config = case @global_config
             in Hash => h
               # Transform string keys to symbol keys for ConfigData compatibility
               symbol_hash = h.transform_keys(&:to_sym)
               ConfigData.new(**symbol_hash)
             else
               ConfigData.new
             end
    yield config
    @global_config = config.to_h
  end

  attr_reader :routes, :routes_literal, :routes_static, :route_definitions, :option, :static_route,
              :security_config, :locale_config, :auth_config, :route_handler_factory, :mcp_server, :security, :middleware
  attr_accessor :not_found, :server_error

  def initialize(path = nil, opts = {})
    initialize_core_state
    initialize_options(path, opts)
    initialize_configurations(opts)

    Otto.logger.debug "new Otto: #{opts}" if Otto.debug
    load(path) unless path.nil?
    super()
  end
  alias options option

  # Main Rack application interface
  def call(env)
    # Apply middleware stack
    base_app = ->(e) { handle_request(e) }

    # Use the middleware stack as the source of truth
    app = @middleware.build_app(base_app, @security_config)

    begin
      app.call(env)
    rescue StandardError => e
      handle_error(e, env)
    end
  end

  # Middleware Management
  def use(middleware, ...)
    @middleware.add(middleware, ...)
  end

  # Compatibility method for existing tests
  def middleware_stack
    @middleware.middleware_list
  end

  # Compatibility method for existing tests
  def middleware_stack=(stack)
    @middleware.clear!
    Array(stack).each { |middleware| @middleware.add(middleware) }
  end

  # Compatibility method for middleware detection
  def middleware_enabled?(middleware_class)
    @middleware.includes?(middleware_class)
  end

  # Security Configuration Methods

  # Enable CSRF protection for POST, PUT, DELETE, and PATCH requests.
  # This will automatically add CSRF tokens to HTML forms and validate
  # them on unsafe HTTP methods.
  #
  # @example
  #   otto.enable_csrf_protection!
  def enable_csrf_protection!
    return if @middleware.includes?(Otto::Security::Middleware::CSRFMiddleware)

    @security_config.enable_csrf_protection!
    use Otto::Security::Middleware::CSRFMiddleware
  end

  # Enable request validation including input sanitization, size limits,
  # and protection against XSS and SQL injection attacks.
  #
  # @example
  #   otto.enable_request_validation!
  def enable_request_validation!
    return if @middleware.includes?(Otto::Security::Middleware::ValidationMiddleware)

    @security_config.input_validation = true
    use Otto::Security::Middleware::ValidationMiddleware
  end

  # Enable rate limiting to protect against abuse and DDoS attacks.
  # This will automatically add rate limiting rules based on client IP.
  #
  # @param options [Hash] Rate limiting configuration options
  # @option options [Integer] :requests_per_minute Maximum requests per minute per IP (default: 100)
  # @option options [Hash] :custom_rules Custom rate limiting rules
  # @example
  #   otto.enable_rate_limiting!(requests_per_minute: 50)
  def enable_rate_limiting!(options = {})
    return if @middleware.includes?(Otto::Security::Middleware::RateLimitMiddleware)

    @security.configure_rate_limiting(options)
    use Otto::Security::Middleware::RateLimitMiddleware
  end

  # Add a custom rate limiting rule.
  #
  # @param name [String, Symbol] Rule name
  # @param options [Hash] Rule configuration
  # @option options [Integer] :limit Maximum requests
  # @option options [Integer] :period Time period in seconds (default: 60)
  # @option options [Proc] :condition Optional condition proc that receives request
  # @example
  #   otto.add_rate_limit_rule('uploads', limit: 5, period: 300, condition: ->(req) { req.post? && req.path.include?('upload') })
  def add_rate_limit_rule(name, options)
    @security_config.rate_limiting_config[:custom_rules] ||= {}
    @security_config.rate_limiting_config[:custom_rules][name.to_s] = options
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

  # Enable authentication middleware for route-level access control.
  # This will automatically check route auth parameters and enforce authentication.
  #
  # @example
  #   otto.enable_authentication!
  def enable_authentication!
    return if @middleware.includes?(Otto::Security::Authentication::AuthenticationMiddleware)

    use Otto::Security::Authentication::AuthenticationMiddleware, @auth_config
  end

  # Add a single authentication strategy
  #
  # @param name [String] Strategy name
  # @param strategy [Otto::Security::Authentication::AuthStrategy] Strategy instance
  # @example
  #   otto.add_auth_strategy('custom', MyCustomStrategy.new)
  def add_auth_strategy(name, strategy)
    # Ensure auth_config is initialized (handles edge case where it might be nil)
    @auth_config = { auth_strategies: {}, default_auth_strategy: 'noauth' } if @auth_config.nil?

    @auth_config[:auth_strategies][name] = strategy

    enable_authentication!
  end

  # Enable MCP (Model Context Protocol) server support
  #
  # @param options [Hash] MCP configuration options
  # @option options [Boolean] :http Enable HTTP endpoint (default: true)
  # @option options [Boolean] :stdio Enable STDIO communication (default: false)
  # @option options [String] :endpoint HTTP endpoint path (default: '/_mcp')
  # @example
  #   otto.enable_mcp!(http: true, endpoint: '/api/mcp')
  def enable_mcp!(options = {})
    @mcp_server ||= Otto::MCP::Server.new(self)

    @mcp_server.enable!(options)
    Otto.logger.info '[MCP] Enabled MCP server' if Otto.debug
  end

  # Check if MCP is enabled
  # @return [Boolean]
  def mcp_enabled?
    @mcp_server&.enabled?
  end

  private

  def initialize_core_state
    @routes_static     = { GET: {} }
    @routes            = { GET: [] }
    @routes_literal    = { GET: {} }
    @route_definitions = {}
    @security_config   = Otto::Security::Config.new
    @middleware        = Otto::Core::MiddlewareStack.new
    # Initialize @auth_config first so it can be shared with the configurator
    @auth_config       = { auth_strategies: {}, default_auth_strategy: 'noauth' }
    @security          = Otto::Security::Configurator.new(@security_config, @middleware, @auth_config)
  end

  def initialize_options(_path, opts)
    @option = {
      public: nil,
      locale: 'en',
    }.merge(opts)
    @route_handler_factory = opts[:route_handler_factory] || Otto::RouteHandlers::HandlerFactory
  end

  def initialize_configurations(opts)
    # Configure locale support (merge global config with instance options)
    configure_locale(opts)

    # Configure security based on options
    configure_security(opts)

    # Configure authentication based on options
    configure_authentication(opts)

    # Initialize MCP server
    configure_mcp(opts)
  end

  class << self
    attr_accessor :debug, :logger, :global_config # rubocop:disable ThreadSafety/ClassAndModuleAttributes
  end

  # Class methods for Otto framework providing singleton access and configuration
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
