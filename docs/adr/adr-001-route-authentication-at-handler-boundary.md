# ADR-001: Enforce route authentication at the handler boundary

- **Status:** Accepted
- **Date:** 2025-10-10

## Context

Route declarations carry their `auth=` requirements. Authentication middleware
runs before routing, so it cannot reliably inspect the matched route or enforce
that requirement. That left route-level authentication dependent on application
code instead of Otto's routing contract.

## Decision

Otto enforces authentication with `RouteAuthWrapper`, which wraps a route handler
after Otto has resolved the route and before the application handler runs. The
wrapper reads the route definition, executes its configured authentication
strategy or strategy chain, and stores the resulting `StrategyResult` in the
request environment.

Routes without `auth=` receive an anonymous `StrategyResult`. This gives Logic
classes a consistent context while preserving public-route behavior.

## Consequences

- `auth=` is enforced at the point where the route definition is available.
- Authentication remains handler-level architecture, not a global middleware
  concern.
- Logic classes and handlers can rely on `env['otto.strategy_result']` being set
  when authentication is configured.
- Authentication strategy registration must finish before the first request,
  when Otto freezes configuration.

## Related documentation

- [Authentication and authorization guide](../guides/authentication.md)
- [Route syntax reference](../reference/route-syntax.md)
- [ADR-002: Multi-strategy authentication and authorization](adr-002-multi-strategy-authentication-and-authorization.md)
