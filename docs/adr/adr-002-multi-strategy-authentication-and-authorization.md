# ADR-002: Use ordered authentication strategy chains and two-layer authorization

- **Status:** Accepted
- **Date:** 2025-11

## Context

An Otto route may need to accept more than one credential mechanism, such as a
browser session and an API key. Authentication must support that without making
invalid explicit credentials silently fall back to anonymous access. It must also
separate broad route access checks from authorization that depends on a loaded
resource.

## Decision

Use a comma-separated `auth=` value for an ordered, OR-based strategy chain:

```text
GET /api/data  Api::Data#show auth=session,api_key response=json
```

Otto validates all named strategies before it executes the chain. Strategies run
left to right, and the first authenticated result wins. Plain failures allow the
next strategy to run. An anonymous result, such as `noauth`, is held as a
fallback until the chain completes. A terminal `AuthFailure` stops the chain and
returns an authentication failure; it is reserved for explicitly presented
credentials that were examined and rejected.

Use `role=` for broad route-level authorization after authentication. Multiple
roles use OR logic. Perform ownership, relationship, and other resource-specific
authorization in a Logic class's `raise_concerns` method; raise
`Otto::Security::AuthorizationError` when access is denied.

## Consequences

- A route can accept multiple credential types without duplicate handlers.
- Strategy declaration order determines the order of ordinary attempts, but a
  terminal failure always fails closed.
- Unknown strategy names fail before any configured strategy runs, preventing a
  partially configured route from serving traffic.
- Missing authentication results in `401`; a valid subject denied by a strategy,
  role check, or resource check results in `403`.
- Applications should configure inexpensive, common strategies first and mark a
  failure terminal only when explicit credentials were rejected.

## Related documentation

- [Authentication and authorization guide](../guides/authentication.md)
- [Route syntax reference](../reference/route-syntax.md)
- [ADR-001: Route authentication at the handler boundary](adr-001-route-authentication-at-handler-boundary.md)
