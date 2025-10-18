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

    # REMOVED: Use strategy_result.user instead
    # USER = 'otto.user'

    # REMOVED: Use strategy_result.metadata instead
    # USER_CONTEXT = 'otto.user_context'

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
    # PRIVACY (IP MASKING)
    # =========================================================================

    # Privacy-safe masked IP address
    # Type: String (e.g., '192.168.1.0')
    # Set by: IPPrivacyMiddleware
    # Used by: Rate limiting, analytics, logging
    module Privacy
      MASKED_IP = 'otto.privacy.masked_ip'

      # Geo-location country code
      # Type: String (ISO 3166-1 alpha-2)
      # Set by: IPPrivacyMiddleware
      # Used by: Analytics, localization
      GEO_COUNTRY = 'otto.privacy.geo_country'

      # Daily-rotating IP hash for session correlation
      # Type: String (hexadecimal)
      # Set by: IPPrivacyMiddleware
      # Used by: Session correlation without storing IPs
      HASHED_IP = 'otto.privacy.hashed_ip'

      # Privacy fingerprint object
      # Type: Otto::Privacy::RedactedFingerprint
      # Set by: IPPrivacyMiddleware
      # Used by: Full privacy context access
      FINGERPRINT = 'otto.privacy.fingerprint'
    end

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
