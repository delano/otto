# frozen_string_literal: true

# lib/otto/env_keys.rb
#
# Central registry of all env['otto.*'] keys used throughout Otto framework.
# This documentation helps prevent key conflicts and aids multi-app integration.

class Otto
  # Rack environment keys used by Otto framework
  #
  # All Otto-specific keys are namespaced under 'otto.*' to avoid conflicts
  # with other Rack middleware or applications.
  module EnvKeys
    # =========================================================================
    # ROUTING & REQUEST FLOW
    # =========================================================================

    # Route definition parsed from routes file
    # Type: Otto::RouteDefinition
    # Set by: Otto::Core::Router#parse_routes
    # Used by: AuthenticationMiddleware, RouteHandlers, LogicClassHandler
    ROUTE_DEFINITION = 'otto.route_definition'

    # Route-specific options parsed from route string
    # Type: Hash (e.g., { response: 'json', csrf: 'exempt', auth: 'authenticated' })
    # Set by: Otto::RouteDefinition#initialize
    # Used by: CSRFMiddleware, RouteHandlers
    ROUTE_OPTIONS = 'otto.route_options'

    # =========================================================================
    # AUTHENTICATION & AUTHORIZATION
    # =========================================================================

    # Authentication strategy result containing session/user state
    # Type: Otto::Security::Authentication::StrategyResult
    # Set by: AuthenticationMiddleware
    # Used by: RouteHandlers, LogicClasses, Controllers
    # Note: Always present (anonymous or authenticated)
    STRATEGY_RESULT = 'otto.strategy_result'

    # Authenticated user object (convenience accessor)
    # Type: Hash, Custom User Object, or nil
    # Set by: AuthenticationMiddleware (from strategy_result.user)
    # Used by: Controllers, RouteHandlers
    USER = 'otto.user'

    # User-specific context (session, roles, permissions, etc.)
    # Type: Hash
    # Set by: AuthenticationMiddleware (from strategy_result.user_context)
    # Used by: Controllers, Analytics
    USER_CONTEXT = 'otto.user_context'

    # =========================================================================
    # SECURITY & CONFIGURATION
    # =========================================================================

    # Security configuration object
    # Type: Otto::Security::Config
    # Set by: Otto#initialize, SecurityConfig
    # Used by: All security middleware (CSRF, Headers, Validation)
    SECURITY_CONFIG = 'otto.security_config'

    # =========================================================================
    # LOCALIZATION (I18N)
    # =========================================================================

    # Resolved locale for current request
    # Type: String (e.g., 'en', 'es', 'fr')
    # Set by: LocaleMiddleware
    # Used by: RouteHandlers, LogicClasses, Views
    LOCALE = 'otto.locale'

    # Locale configuration object
    # Type: Otto::LocaleConfig
    # Set by: LocaleMiddleware
    # Used by: Locale resolution logic
    LOCALE_CONFIG = 'otto.locale_config'

    # Available locales for the application
    # Type: Array<String>
    # Set by: LocaleConfig
    # Used by: Locale middleware, language switchers
    AVAILABLE_LOCALES = 'otto.available_locales'

    # Default/fallback locale
    # Type: String
    # Set by: LocaleConfig
    # Used by: Locale middleware when resolution fails
    DEFAULT_LOCALE = 'otto.default_locale'

    # =========================================================================
    # ERROR HANDLING
    # =========================================================================

    # Unique error ID for tracking/logging
    # Type: String (hex format, e.g., '4ac47cb3a6d177ef')
    # Set by: ErrorHandler, RouteHandlers
    # Used by: Error responses, logging, support
    ERROR_ID = 'otto.error_id'

    # =========================================================================
    # MCP (MODEL CONTEXT PROTOCOL)
    # =========================================================================

    # MCP HTTP endpoint path
    # Type: String (default: '/_mcp')
    # Set by: Otto::MCP::Server#enable!
    # Used by: MCP middleware, SchemaValidationMiddleware
    MCP_HTTP_ENDPOINT = 'otto.mcp_http_endpoint'

    # =========================================================================
    # USAGE EXAMPLES
    # =========================================================================
    #
    # Reading env keys in controllers:
    #
    #   def index(req, res)
    #     strategy_result = req.env[Otto::EnvKeys::STRATEGY_RESULT]
    #     locale = req.env[Otto::EnvKeys::LOCALE] || 'en'
    #
    #     if strategy_result.authenticated?
    #       user = req.env[Otto::EnvKeys::USER]
    #       render_authenticated(user, locale)
    #     end
    #   end
    #
    # Reading env keys in middleware:
    #
    #   class CustomMiddleware
    #     def call(env)
    #       route_def = env[Otto::EnvKeys::ROUTE_DEFINITION]
    #       return @app.call(env) unless route_def
    #
    #       # Custom logic based on route
    #       @app.call(env)
    #     end
    #   end
    #
    # Reading env keys in Logic classes:
    #
    #   class MyLogic < Logic::Base
    #     def initialize(strategy_result, params, locale)
    #       @strategy_result = strategy_result
    #       # Access via: @strategy_result (already extracted from env)
    #     end
    #   end
    #
    # =========================================================================
    # MULTI-APP INTEGRATION
    # =========================================================================
    #
    # For multi-app architectures (e.g., Auth app + Core app + API app):
    #
    # 1. Shared session middleware ensures session state propagates
    # 2. IdentityResolution middleware (app-specific) reads session
    # 3. Otto's AuthenticationMiddleware creates STRATEGY_RESULT from resolved identity
    #
    # Auth App (Roda) manually creates STRATEGY_RESULT for Logic class compatibility:
    #
    #   strategy_result = Otto::Security::Authentication::StrategyResult.new(
    #     session: session,
    #     user: current_customer,
    #     auth_method: 'session',
    #     metadata: { ip: request.ip }
    #   )
    #
    #   # Pass to Logic classes same as Otto controllers
    #   logic = V2::Logic::Authentication::Authenticate.new(
    #     strategy_result, params, locale
    #   )
    #
    # Core/API Apps access user via:
    #   - env[STRATEGY_RESULT] from AuthenticationMiddleware
    #   - env[USER] convenience accessor
    #
    # =========================================================================
    # KEY NAMING CONVENTIONS
    # =========================================================================
    #
    # All keys follow 'otto.<category>.<name>' pattern:
    #
    # - otto.route_definition (routing)
    # - otto.strategy_result (auth)
    # - otto.security_config (security)
    # - otto.locale (i18n)
    # - otto.mcp_http_endpoint (MCP)
    #
    # When adding new keys:
    # 1. Define constant in this file
    # 2. Document type, setter, and users
    # 3. Follow 'otto.*' namespace convention
    # 4. Update this documentation
    #
    # =========================================================================
  end
end
