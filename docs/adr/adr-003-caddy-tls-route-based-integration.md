# ADR-003: Provide Caddy on-demand TLS as a route-based feature integration

- **Status:** Accepted
- **Date:** 2026-07

## Context

Caddy's on-demand TLS permission check has a fixed HTTP contract, but each
application previously had to implement routing, input validation, caller
restriction, response semantics, and failure handling around its domain-allow
policy. A manually wired handler and guard makes it possible to expose the
certificate-issuance endpoint without its required protection.

## Decision

Provide `Otto::CaddyTLS` as an opt-in, feature-named integration. Calling
`enable_caddy_tls!` registers the permission route and, by default, its
path-scoped `LocalhostGuard`; the application supplies only the domain allow or
deny decision.

The guard authorizes a direct loopback socket peer, not a client address derived
from forwarding headers. It also rejects forwarding headers for the protected
path. The endpoint therefore remains loopback-only even in cross-host
deployments: run a small permission app alongside Caddy and let the application
callback use its existing trusted data channel.

The integration fails closed: a missing or invalid `domain` is rejected, a falsey
or exception-raising permission callback denies the request, and enabling the
integration without a callback raises an error. The default endpoint is
`/_caddy/tls-permission`.

## Consequences

- Caddy TLS setup has one code-side entry point that bundles the route, guard,
  and decision callback.
- The endpoint cannot be reached successfully through a public reverse-proxy
  path merely because the proxy connects to Otto over loopback.
- `localhost_only: false` is an explicit opt-out; the deployment must then
  provide network-level isolation.
- A generic network-services registry is not introduced. Future integrations
  should use a feature-specific namespace and promote only mechanisms shared by
  more than one concrete feature.

## Related documentation

- [Caddy on-demand TLS guide](../guides/caddy-tls.md)
- [Caddy TLS example](../../examples/caddy_tls_demo/README.md)
- [`Otto::CaddyTLS::LocalhostGuard`](../../lib/otto/caddy_tls/localhost_guard.rb)
