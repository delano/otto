# lib/otto.rb
#
# frozen_string_literal: true

require 'concurrent'
require 'json'
require 'logger'
require 'securerandom'
require 'uri'

require 'rack/request'
require 'rack/response'
require 'rack/utils'

require_relative 'otto/request'
require_relative 'otto/response'
require_relative 'otto/route_definition'
require_relative 'otto/route'
require_relative 'otto/static'
require_relative 'otto/helpers'
require_relative 'otto/response_handlers'
require_relative 'otto/route_handlers'
require_relative 'otto/errors'
require_relative 'otto/locale'
require_relative 'otto/mcp'
require_relative 'otto/caddy_tls'
require_relative 'otto/core'
require_relative 'otto/privacy'
require_relative 'otto/security'
require_relative 'otto/utils'
require_relative 'otto/version'
require_relative 'otto/logging_helpers'

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
  include Otto::Core::HelperRegistry
  include Otto::Core::MiddlewareManagement
  include Otto::Core::LifecycleHooks
  include Otto::Security::Core
  include Otto::Privacy::Core
  include Otto::MCP::Core
  include Otto::CaddyTLS::Core

  LIB_HOME = __dir__ unless defined?(Otto::LIB_HOME)

  @debug = case ENV.fetch('OTTO_DEBUG', nil)
           in 'true' | '1' | 'yes' | 'on'
             true
           else
             defined?(Otto::Utils) ? Otto::Utils.yes?(ENV.fetch('OTTO_DEBUG', nil)) : false
           end
  @logger = Logger.new($stdout, Logger::INFO)

  attr_reader :routes, :routes_literal, :routes_static, :route_definitions,
              :routes_by_definition, :option,
              :static_route, :security_config, :locale_config, :auth_config,
              :route_handler_factory, :mcp_server, :caddy_tls_server, :security, :middleware,
              :error_handlers, :request_class, :response_class
  attr_accessor :not_found, :server_error

  def initialize(path = nil, opts = {})
    initialize_core_state
    initialize_options(path, opts)
    initialize_configurations(opts)

    Otto.logger.debug "new Otto: #{opts}" if Otto.debug
    load(path) unless path.nil?
    super()

    # Auto-register all Otto framework error classes
    # This allows Logic classes and framework code to raise appropriate errors
    # without requiring manual registration in implementing projects
    register_framework_errors

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

  # Read-only view of assembled instance options. LambdaHandler resolves its
  # registry via otto_instance.config[:lambda_handlers].
  alias config option

  # Main Rack application interface
  def call(env)
    # Freeze configuration on first request (thread-safe).
    # Skipped under RSpec so specs can mutate configuration after construction.
    # Because of this skip, behavior that depends on a genuinely frozen config
    # (e.g. CSP violation dispatch through a frozen Config) is NOT exercised by
    # the normal request path in tests — cover it with specs that freeze
    # explicitly (see spec/otto/security/csp_reporting_frozen_spec.rb and
    # spec/otto/configuration_freezing_spec.rb).
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

    # Track request timing for lifecycle hooks
    start_time = Otto::Utils.now_in_μs
    request = @request_class.new(env)
    response_raw = nil

    begin
      # Use pre-built middleware app (built once at initialization)
      response_raw = @app.call(env)
    rescue StandardError => e
      response_raw = handle_error(e, env)
    ensure
      # Execute request completion hooks if any are registered
      unless @request_complete_callbacks.empty?
        begin
          duration = Otto::Utils.now_in_μs - start_time
          # Wrap response tuple in Otto::Response for developer-friendly API
          # Otto's hook API should provide nice abstractions like Otto::Request/Response
          response = @response_class.new(response_raw[2], response_raw[0], response_raw[1])
          @request_complete_callbacks.each do |callback|
            callback.call(request, response, duration)
          end
        rescue StandardError => e
          Otto.logger.error "[Otto] Request completion hook error: #{e.message}"
          Otto.logger.debug "[Otto] Hook error backtrace: #{e.backtrace.join("\n")}" if Otto.debug
        end
      end
    end

    response_raw
  end

  # Security, Privacy, MCP, Middleware, HelperRegistry, and LifecycleHooks
  # methods are provided by their respective Core modules (see includes above)

  private

  def initialize_core_state
    # The GET cache is a Concurrent::Map, not a plain Hash: lazy static-file
    # discovery (Core::Router#handle_request, Core::FileSafety#add_static_path)
    # writes into it at request time, after freeze_configuration! has already
    # deep-frozen the rest of the routing state. Deep-freezing this cache too
    # would turn every as-yet-uncached static file request into a 500
    # (FrozenError) in production (issue #185), so it is intentionally excluded
    # from deep_freeze_value in Configuration#freeze_configuration! and kept as
    # a structure that is both mutable post-freeze and safe under concurrent
    # request threads.
    @routes_static     = { GET: Concurrent::Map.new }
    @routes            = { GET: [] }
    @routes_literal    = { GET: {} }
    @route_definitions = {}
    # All routes per definition string, in load order. A definition string is
    # not unique — the same handler can be mounted at several verb/path pairs —
    # so reverse lookups (Otto#uri) consult this index instead of the
    # single-route @route_definitions entry (issue #190).
    @routes_by_definition = {}
    @security_config   = Otto::Security::Config.new
    @middleware        = Otto::Core::MiddlewareStack.new
    # Initialize @auth_config first so it can be shared with the configurator
    @auth_config       = { auth_strategies: {}, default_auth_strategy: 'noauth' }
    @security          = Otto::Security::Configurator.new(@security_config, @middleware, @auth_config)
    @app               = nil # Pre-built middleware app (built after initialization)

    # Keep the running Rack app in sync with the middleware stack. This is the
    # SINGLE rebuild trigger: any add/remove/clear — whether via Otto#use,
    # otto.enable_*!, or the otto.security.* Configurator surface — rebuilds @app
    # once it exists. Without it, middleware added through the Configurator after
    # Otto.new would register in the stack but never enter the running request
    # chain, silently disabling CSRF, request validation, rate limiting, and CSP
    # reporting configured that way.
    #
    # The `if @app` guard makes stack mutations during initialization (e.g. the
    # IP-privacy add below) no-ops until the first build_app! runs. A rebuild
    # during a live request could swap @app mid-flight under multi-threaded
    # serving; Otto's contract is to configure before the first request, which
    # the lazy configuration freeze enforces in production.
    @middleware.on_change { build_app! if @app }

    @request_complete_callbacks = [] # Instance-level request completion callbacks
    @route_matched_callbacks    = [] # Instance-level route matched callbacks
    @handler_wrappers           = [] # Instance-level handler wrapper factories
    @error_handlers             = {} # Registered error handlers for expected errors

    # Initialize helper module registries
    @request_helper_modules = []
    @response_helper_modules = []

    # Finalize request/response classes with built-in helpers
    # Custom helpers can be registered via register_request_helpers/register_response_helpers
    # before first request (before configuration freezing)
    finalize_request_response_classes

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

    # Validate and freeze the lambda handler registry (issue #41).
    # Runs last so misconfiguration fails fast at construction.
    configure_lambda_handlers(opts)
  end

  class << self
    attr_accessor :debug # rubocop:disable ThreadSafety/ClassAndModuleAttributes
    attr_writer :logger # rubocop:disable ThreadSafety/ClassAndModuleAttributes

    # Otto's logger. Never nil: falls back to a default $stdout logger so call
    # sites can log unconditionally without defensive `&.` guards. Assign your
    # own logger (or a null logger to silence) via `Otto.logger = ...`.
    def logger
      @logger ||= Logger.new($stdout, Logger::INFO)
    end

    # Helper method for structured logging that works with both standard Logger and structured loggers
    def structured_log(level, message, data = {})
      return unless logger

      # Skip debug logging when Otto.debug is false
      return if level == :debug && !debug

      # Sanitize backtrace if present
      if data.is_a?(Hash) && data[:backtrace].is_a?(Array)
        data = data.dup
        data[:backtrace] = Otto::LoggingHelpers.sanitize_backtrace(data[:backtrace])
      end

      # Try structured logging first (SemanticLogger, etc.)
      if logger.respond_to?(level) && logger.method(level).arity > 1
        logger.send(level, message, data)
      else
        # Fallback to standard logger with formatted string
        formatted_data = data.empty? ? '' : " -- #{data.inspect}"
        logger.send(level, "[Otto] #{message}#{formatted_data}")
      end
    end
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
      guesses.flatten.any? { |n| ENV['RACK_ENV'].to_s == n.to_s }
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
      raise 'Otto.unfreeze_for_testing is only available in RSpec test environment' unless defined?(RSpec)

      otto.instance_variable_set(:@configuration_frozen, false)
      otto
    end
  end
  extend ClassMethods
end
