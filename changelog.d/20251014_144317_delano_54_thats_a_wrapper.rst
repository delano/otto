Changed
-------

- Authentication now handled by RouteAuthWrapper at handler level instead of middleware
- RouteAuthWrapper enhanced with session persistence, security headers, strategy caching, and sophisticated pattern matching
- env['otto.strategy_result'] now GUARANTEED to be present on all routes (authenticated or anonymous)
- RouteAuthWrapper now wraps all route handlers, not just routes with auth requirements

Removed
-------

- Removed AuthenticationMiddleware (architecturally broken - executed before routing)
- Removed enable_authentication! (no longer needed - RouteAuthWrapper handles auth automatically)
- Removed defensive nil fallback from LogicClassHandler (no longer needed)

Fixed
-----

- Session persistence now works correctly (env['rack.session'] references same object as strategy_result.session)
- Security headers now included on all authentication failure responses (401/302)
- Strategy lookups now cached for performance
- env['otto.strategy_result'] is now guaranteed to be present (anonymous StrategyResult for public routes)
- Routes without auth requirements now get anonymous StrategyResult with IP metadata

Security
--------

- Authentication strategies now execute after routing when route_definition is available
- Supports exact match, prefix match (role:admin), and fallback patterns for strategies

Documentation
-------------

- Updated CLAUDE.md with RouteAuthWrapper architecture overview
- Updated env_keys.rb to document guaranteed presence of strategy_result
- Added comprehensive tests for anonymous route handling
