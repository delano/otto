Changed
-------

- Authentication now handled by RouteAuthWrapper at handler level instead of middleware
- RouteAuthWrapper enhanced with session persistence, security headers, strategy caching, and sophisticated pattern matching

Removed
-------

- Removed AuthenticationMiddleware (architecturally broken - executed before routing)
- Removed enable_authentication! (no longer needed - RouteAuthWrapper handles auth automatically)

Fixed
-----

- Session persistence now works correctly (env['rack.session'] references same object as strategy_result.session)
- Security headers now included on all authentication failure responses (401/302)
- Strategy lookups now cached for performance

Security
--------

- Authentication strategies now execute after routing when route_definition is available
- Supports exact match, prefix match (role:admin), and fallback patterns for strategies
