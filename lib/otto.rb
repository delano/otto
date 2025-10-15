# frozen_string_literal: true

# lib/otto.rb

require 'json'
require 'logger'
require 'securerandom'
require 'uri'

require 'rack/request'
require 'rack/response'
require 'rack/utils'

require_relative 'otto/route_definition'
require_relative 'otto/route'
require_relative 'otto/static'
require_relative 'otto/helpers'
require_relative 'otto/response_handlers'
require_relative 'otto/route_handlers'
require_relative 'otto/locale/config'
require_relative 'otto/mcp'
require_relative 'otto/core'
require_relative 'otto/privacy'
require_relative 'otto/security'
require_relative 'otto/utils'
require_relative 'otto/version'

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
  @logger = Logger.new($stdout, Logger::INFO)

  attr_reader :routes, :routes_literal, :routes_static, :route_definitions, :option,
              :static_route, :security_config, :locale_config, :auth_config,
              :route_handler_factory, :mcp_server, :security, :middleware
  attr_accessor :not_found, :server_error

  def initialize(path = nil, opts = {})
    initialize_core_state
    initialize_options(path, opts)
    initialize_configurations(opts)

    Otto.logger.debug "new Otto: #{opts}" if Otto.debug
    load(path) unless path.nil?
    super()

    # Build the middleware app once after all initialization is complete
    build_app!

    # Configuration freezing is deferred until first request to support
    # multi-step initialization (e.g., multi-app architectures).
    # This allows adding auth strategies, middleware, etc. after Otto.new
    # but before processing requests.
    @freeze_mutex = Mutex.new
    @configuration_frozen = false
  end
  alias options option

  # Main Rack application interface
  def call(env)
    # Freeze configuration on first request (thread-safe)
    # Skip in test environment to allow test flexibility
    unless defined?(RSpec) || @configuration_frozen
      Otto.logger.debug '[Otto] Lazy freezing check: configuration not yet frozen' if Otto.debug

      @freeze_mutex.synchronize do
        unless @configuration_frozen
          Otto.logger.info '[Otto] Freezing configuration on first request (lazy freeze)'
          freeze_configuration!
          @configuration_frozen = true
          Otto.logger.debug '[Otto] Configuration frozen successfully' if Otto.debug
        end
      end
    end

    begin
      # Use pre-built middleware app (built once at initialization)
      @app.call(env)
    rescue StandardError => e
      handle_error(e, env)
    end
  end

  # Builds the middleware application chain
  # Called once at initialization and whenever middleware stack changes
  #
  # IMPORTANT: If you have routes with auth requirements, you MUST add session
  # middleware to your middleware stack BEFORE Otto processes requests.
  #
  # Session middleware is required for RouteAuthWrapper to correctly persist
  # session changes during authentication. Common options include:
  # - Rack::Session::Cookie (requires rack-session gem)
  # - Rack::Session::Pool
  # - Rack::Session::Memcache
  # - Any Rack-compatible session middleware
  #
  # Example:
  #   use Rack::Session::Cookie, secret: ENV['SESSION_SECRET']
  #   otto = Otto.new('routes.txt')
  #
  def build_app!
    base_app = method(:handle_request)
    @app = @middleware.wrap(base_app, @security_config)
  end

  # Middleware Management
  def use(middleware, ...)
    ensure_not_frozen!
    @middleware.add(middleware, ...)

    # NOTE: If build_app! is triggered during a request (via use() or
    # middleware_stack=), the @app instance variable could be swapped
    # mid-request in a multi-threaded environment.

    build_app! if @app  # Rebuild app if already initialized
  end

  # Compatibility method for existing tests
  def middleware_stack
    @middleware.middleware_list
  end

  # Compatibility method for existing tests
  def middleware_stack=(stack)
    @middleware.clear!
    Array(stack).each { |middleware| @middleware.add(middleware) }
    build_app! if @app  # Rebuild app if already initialized
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
    ensure_not_frozen!
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
    ensure_not_frozen!
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
    ensure_not_frozen!
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
    ensure_not_frozen!
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
    ensure_not_frozen!
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
    ensure_not_frozen!
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
    ensure_not_frozen!
    @security_config.enable_hsts!(max_age: max_age, include_subdomains: include_subdomains)
  end

  # Enable Content Security Policy (CSP) header to prevent XSS attacks.
  # The default policy only allows resources from the same origin.
  #
  # @param policy [String] CSP policy string (default: "default-src 'self'")
  # @example
  #   otto.enable_csp!("default-src 'self'; script-src 'self' 'unsafe-inline'")
  def enable_csp!(policy = "default-src 'self'")
    ensure_not_frozen!
    @security_config.enable_csp!(policy)
  end

  # Enable X-Frame-Options header to prevent clickjacking attacks.
  #
  # @param option [String] Frame options: 'DENY', 'SAMEORIGIN', or 'ALLOW-FROM uri'
  # @example
  #   otto.enable_frame_protection!('DENY')
  def enable_frame_protection!(option = 'SAMEORIGIN')
    ensure_not_frozen!
    @security_config.enable_frame_protection!(option)
  end

  # Enable Content Security Policy (CSP) with nonce support for dynamic header generation.
  # This enables the res.send_csp_headers response helper method.
  #
  # @param debug [Boolean] Enable debug logging for CSP headers (default: false)
  # @example
  #   otto.enable_csp_with_nonce!(debug: true)
  def enable_csp_with_nonce!(debug: false)
    ensure_not_frozen!
    @security_config.enable_csp_with_nonce!(debug: debug)
  end

  # Add a single authentication strategy
  #
  # @param name [String] Strategy name
  # @param strategy [Otto::Security::Authentication::AuthStrategy] Strategy instance
  # @example
  #   otto.add_auth_strategy('custom', MyCustomStrategy.new)
  def add_auth_strategy(name, strategy)
    ensure_not_frozen!
    # Ensure auth_config is initialized (handles edge case where it might be nil)
    @auth_config = { auth_strategies: {}, default_auth_strategy: 'noauth' } if @auth_config.nil?

    @auth_config[:auth_strategies][name] = strategy
  end

  # Disable IP privacy to access original IP addresses
  #
  # IMPORTANT: By default, Otto masks public IP addresses for privacy.
  # Private/localhost IPs (127.0.0.0/8, 10.0.0.0/8, etc.) are never masked.
  # Only disable this if you need access to original public IPs.
  #
  # When disabled:
  # - env['REMOTE_ADDR'] contains the real IP address
  # - env['otto.original_ip'] also contains the real IP
  # - No PrivateFingerprint is created
  #
  # @example
  #   otto.disable_ip_privacy!
  def disable_ip_privacy!
    ensure_not_frozen!
    @security_config.ip_privacy_config.disable!
  end

  # Configure IP privacy settings
  #
  # Privacy is enabled by default. Use this method to customize privacy
  # behavior without disabling it entirely.
  #
  # @param mask_level [Integer] Number of octets to mask (1 or 2, default: 1)
  # @param hash_rotation [Integer] Seconds between key rotation (default: 86400)
  # @param geo [Boolean] Enable geo-location resolution (default: true)
  #
  # @example Mask 2 octets instead of 1
  #   otto.configure_ip_privacy(mask_level: 2)
  #
  # @example Disable geo-location
  #   otto.configure_ip_privacy(geo: false)
  #
  # @example Custom hash rotation
  #   otto.configure_ip_privacy(hash_rotation: 12.hours)
  def configure_ip_privacy(mask_level: nil, hash_rotation: nil, geo: nil)
    ensure_not_frozen!
    config = @security_config.ip_privacy_config

    config.mask_level = mask_level if mask_level
    config.hash_rotation_period = hash_rotation if hash_rotation
    config.geo_enabled = geo unless geo.nil?

    # Validate configuration
    config.validate!
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
    ensure_not_frozen!
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
    @app               = nil  # Pre-built middleware app (built after initialization)

    # Add IP Privacy middleware first in stack (privacy by default for public IPs)
    # Private/localhost IPs are automatically exempted from masking
    @middleware.add_with_position(
      Otto::Security::Middleware::IPPrivacyMiddleware,
      position: :first
    )
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
    attr_accessor :debug, :logger # rubocop:disable ThreadSafety/ClassAndModuleAttributes
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

    # Test-only method to unfreeze Otto configuration
    #
    # This method resets the @configuration_frozen flag, allowing tests
    # to bypass the ensure_not_frozen! check. It does NOT actually unfreeze
    # Ruby objects (which is impossible once frozen).
    #
    # IMPORTANT: Only works when RSpec is defined. Raises an error otherwise
    # to prevent accidental use in production.
    #
    # @param otto [Otto] The Otto instance to unfreeze
    # @return [Otto] The unfrozen Otto instance
    # @raise [RuntimeError] if RSpec is not defined (not in test environment)
    # @api private
    def unfreeze_for_testing(otto)
      unless defined?(RSpec)
        raise 'Otto.unfreeze_for_testing is only available in RSpec test environment'
      end

      otto.instance_variable_set(:@configuration_frozen, false)
      otto
    end
  end
  extend ClassMethods
end
