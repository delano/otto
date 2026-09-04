# Architecture decision records

Architecture decision records (ADRs) document durable technical decisions that
shape Otto's architecture. They preserve the context, decision, and consequences
without replacing the supported application documentation.

## Records

- [ADR-001: Enforce route authentication at the handler boundary](adr-001-route-authentication-at-handler-boundary.md)
- [ADR-002: Use ordered authentication strategy chains and two-layer authorization](adr-002-multi-strategy-authentication-and-authorization.md)
- [ADR-003: Provide Caddy on-demand TLS as a route-based feature integration](adr-003-caddy-tls-route-based-integration.md)
- [ADR-004: Separate compatibility support from security maintenance](adr-004-separate-compatibility-from-security-maintenance.md)

New records use the next three-digit sequence number and describe their status,
context, decision, and consequences. Update a record's status when a later ADR
supersedes it; do not rewrite accepted decisions to reflect later changes.
