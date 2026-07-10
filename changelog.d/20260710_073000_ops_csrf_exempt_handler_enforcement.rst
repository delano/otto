Security
--------

- ``csrf=exempt`` is now enforced (#186). CSRF token validation moved from the
  global ``CSRFMiddleware`` — which runs ahead of route matching and therefore
  could not see per-route options, making ``csrf=exempt`` a silent no-op — to a
  handler-layer ``Otto::Security::CSRFEnforcementWrapper`` that the handler
  factory applies (when CSRF protection is enabled) after a route is matched,
  where ``route_definition.csrf_exempt?`` is available. A tokenless unsafe
  request to an exempt route is now served; the same request to a non-exempt
  route is still rejected with 403. The wrapper is composed outside
  ``RouteAuthWrapper`` so a forged request is rejected before any authentication
  work runs, and applies uniformly to every handler kind (class/instance/logic/
  lambda) via the shared factory. ``CSRFMiddleware`` retains only token
  injection into HTML responses.

  Behavior change for anyone using ``Otto::Security::Middleware::CSRFMiddleware``
  standalone: it no longer blocks unsafe requests on its own — enforcement is
  applied by Otto's route handler pipeline. The token mechanics are shared via
  the new ``Otto::Security::CSRFValidation`` module so injection and enforcement
  cannot drift.
