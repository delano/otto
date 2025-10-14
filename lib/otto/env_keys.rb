# lib/otto/env_keys.rb
#
# Central registry of all env['otto.*'] keys used throughout Otto framework.
# This documentation helps prevent key conflicts and aids multi-app integration.
#
# DOCUMENTATION-ONLY MODULE: The constants defined here are intentionally NOT used
# in the codebase. Otto uses string literals (e.g., env['otto.strategy_result'])
# for readibility/simplicity. This module exists as reference documentation but
# may be considered for future use if needed.
#
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
    # Set by: RouteAuthWrapper (wraps all route handlers)
    # Used by: RouteHandlers, LogicClasses, Controllers
    # Guarantee: ALWAYS present - either authenticated or anonymous
    # - Routes WITH auth requirement: Authenticated StrategyResult or 401/302
    # - Routes WITHOUT auth requirement: Anonymous StrategyResult
    STRATEGY_RESULT = 'otto.strategy_result'

    # Authenticated user object (convenience accessor)
    # Type: Hash, Custom User Object, or nil
    # Set by: RouteAuthWrapper (from strategy_result.user)
    # Used by: Controllers, RouteHandlers
    # Note: nil for anonymous/unauthenticated requests
    USER = 'otto.user'

    # User-specific context (session, roles, permissions, etc.)
    # Type: Hash
    # Set by: RouteAuthWrapper (from strategy_result.user_context)
    # Used by: Controllers, Analytics
    # Note: Empty hash {} for anonymous requests
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
  end
end
