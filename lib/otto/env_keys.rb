# lib/otto/env_keys.rb
#
# frozen_string_literal: true
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

    # Per-request CSP nonce, minted lazily on first access and memoized here.
    # Type: String (base64)
    # Set by: Otto::Security::CSP.nonce / Otto::Request#csp_nonce (first touch)
    # Used by: views (stamping script/style nonces) and
    #   Otto::Security::CSP::EmitMiddleware (emit-if-consumed)
    # Note: this is the DEFAULT key. Apps with an existing convention can point
    #   the accessor at their own key via Otto::Security::Config#csp_nonce_key
    #   (e.g. 'onetime.nonce'), so the header and views still share one value.
    NONCE = 'otto.nonce'

    # Whether the request arrived via a trusted proxy.
    # Type: Boolean
    # Set by: IPPrivacyMiddleware (every request, evaluated on the original
    #   peer BEFORE REMOTE_ADDR is masked). This is the trusted-proxy identity
    #   check (does REMOTE_ADDR match a configured trusted_proxies CIDR?) — it is
    #   independent of count-based depth mode, which resolves the client IP but
    #   never grants proxy trust for forwarded proto.
    # Used by: Otto::Request#secure? to authorize X-Forwarded-Proto / X-Scheme
    #   without depending on the (masked) REMOTE_ADDR
    VIA_TRUSTED_PROXY = 'otto.via_trusted_proxy'

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

    # Canonical client IP, resolved once early by IPPrivacyMiddleware
    # ("resolve once, read everywhere"). Downstream code (client_ipaddress,
    # Request#ip) reads this instead of re-deriving from REMOTE_ADDR / XFF.
    # Type: String
    # Set by: IPPrivacyMiddleware (every request, all modes)
    # Value: masked IP when privacy enabled; resolved real IP when privacy
    #        disabled or the address is exempt (private/localhost)
    # Note: presence also acts as the idempotency guard for the middleware
    CLIENT_IP = 'otto.client_ip'

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

      # Stable IP correlation hash: identifies the same visitor across days/months
      # Type: String (hexadecimal), or nil when no correlation secret configured
      # Set by: IPPrivacyMiddleware (computed over the FULL client IP,
      #   pre-masking, keyed with the caller-configured stable
      #   correlation_secret — NOT the daily rotation_key behind HASHED_IP)
      # Used by: Correlating the same visitor across days/months (e.g. audit
      #   trails) without ever storing or exposing the real IP
      # Read via: Otto::Request#ip_correlation_hash
      # Contrast: HASHED_IP rotates daily (session-scoped); this is stable.
      CORRELATION_HASH = 'otto.privacy.correlation_hash'

      # Privacy fingerprint object
      # Type: Otto::Privacy::RedactedFingerprint
      # Set by: IPPrivacyMiddleware
      # Used by: Full privacy context access
      FINGERPRINT = 'otto.privacy.fingerprint'
    end

    # =========================================================================
    # ORIGINAL VALUES (Privacy Disabled)
    # =========================================================================

    # Original client IP address (only when privacy disabled)
    # Type: String
    # Set by: IPPrivacyMiddleware (when privacy disabled)
    # Used by: Debugging, legitimate use cases requiring real IP
    # NOTE: Not available when privacy is enabled (intentional)
    ORIGINAL_IP = 'otto.original_ip'

    # Original User-Agent string (only when privacy disabled)
    # Type: String
    # Set by: IPPrivacyMiddleware (when privacy disabled)
    # Used by: Bot detection, browser feature detection
    # NOTE: Not available when privacy is enabled (intentional)
    ORIGINAL_USER_AGENT = 'otto.original_user_agent'

    # Original Referer URL (only when privacy disabled)
    # Type: String
    # Set by: IPPrivacyMiddleware (when privacy disabled)
    # Used by: Analytics, debugging
    # NOTE: Not available when privacy is enabled (intentional)
    ORIGINAL_REFERER = 'otto.original_referer'

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
