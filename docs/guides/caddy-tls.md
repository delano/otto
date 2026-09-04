# Caddy on-demand TLS

`Otto::CaddyTLS` provides the permission endpoint Caddy calls before obtaining
or loading a certificate for a domain. Otto owns the route, request validation,
access guard, response semantics, and fail-closed behavior. The application
supplies one decision block: whether the requested domain is allowed.

This guide covers the shipped integration. [ADR-003: Caddy TLS route-based
integration](../adr/adr-003-caddy-tls-route-based-integration.md) explains the
rejected alternatives and the security rationale in more detail.

## Enable the endpoint

Configure it before the first request:

```ruby
require 'otto'

otto = Otto.new('routes')
otto.enable_caddy_tls! do |domain|
  MyApp::CustomDomain.verified?(domain)
end

run otto
```

The block receives the stripped `domain` string from `?domain=`. A truthy result
returns `200 OK`; a falsey result returns `403 Forbidden`. An exception raised by
the block is logged and treated as a denial.

The default endpoint is `/_caddy/tls-permission`. No entry in the routes file is
required. Enabling without a block raises `ArgumentError`, and repeated enable
calls are idempotent: the first configuration and decision block remain active.

## Configure Caddy

Caddy's current HTTP permission module and the older `ask` directive use the
same Otto endpoint contract:

```caddyfile
on_demand_tls {
  permission http {
    endpoint http://127.0.0.1:PORT/_caddy/tls-permission
  }
}
```

For older configurations:

```caddyfile
on_demand_tls {
  ask http://127.0.0.1:PORT/_caddy/tls-permission
}
```

Replace `PORT` with the loopback port serving the Otto endpoint. Caddy treats a
non-`2xx` response as a denial.

## Request contract

The endpoint accepts a `GET` request with a string `domain` query parameter:

| Request | Result |
| --- | --- |
| `GET /_caddy/tls-permission?domain=verified.example` and callback allows | `200`, `text/plain`, `OK` |
| Domain missing, blank, or array-valued | `400`, callback is not called |
| Callback returns false or `nil` | `403`, `text/plain`, `Forbidden` |
| Callback raises | `403`, callback error is logged |
| `HEAD` with a valid domain | Same status decision, empty response body |

Only `domain` reaches the callback. Additional query parameters are ignored;
there is no verification-bypass parameter.

## Security boundary

The localhost guard is enabled by default. For the protected endpoint, both
conditions must hold:

1. the raw socket peer is loopback; and
2. no forwarding header indicates that the request was relayed through another
   proxy.

The guard authenticates the original peer, not the resolved client address in
`REMOTE_ADDR` or `otto.client_ip`. This matters when a loopback proxy is also a
trusted proxy: forwarded headers must not be able to turn a remote caller into a
local one. The guard rejects these forwarding headers on the endpoint:

- `X-Forwarded-For`
- `X-Real-IP`
- `X-Client-IP`
- `Forwarded`

The guard is path-scoped. Other application routes pass through it unchanged,
and path normalization is shared with the router so encoded or trailing-slash
variants cannot bypass the check.

## Deployment topology

The recommended deployment is a small Otto app bound to a loopback-only port on
the same host as Caddy:

```text
Caddy -- loopback --> Otto CaddyTLS endpoint -- authenticated app channel --> domain data
```

The permission app may query a database, internal API, or cache in its decision
block. That data channel is an application responsibility; it does not widen
the Caddy endpoint's network trust boundary.

If the endpoint is mounted in a larger public app, add defense in depth:

- bind a dedicated permission app to `127.0.0.1` where possible;
- block the endpoint path at the public proxy;
- ensure the proxy's direct Caddy control-plane request is not relayed with
  forwarding headers;
- keep the guard enabled unless network isolation is independently enforced.

## Disabling the guard

`localhost_only: false` removes the built-in access control and logs a warning:

```ruby
otto.enable_caddy_tls!(localhost_only: false) do |domain|
  MyApp::CustomDomain.verified?(domain)
end
```

Use this only when the endpoint is isolated by a stronger network-level control
that you have verified. It is not the normal deployment path.

## Custom endpoint

An application can choose another endpoint path:

```ruby
otto.enable_caddy_tls!(endpoint: '/internal/acme/permission') do |domain|
  MyApp::CustomDomain.verified?(domain)
end
```

Otto normalizes the configured endpoint before registering the route and guard.
The endpoint must still be configured before the first request; attempting to
change it after configuration freezes raises `FrozenError`.

## Troubleshooting

- **Caddy receives a denial:** check that the request reaches the configured
  loopback port, includes a non-empty `domain`, and that the callback returns
  truthy for that exact stripped domain.
- **The callback is never called:** a missing/blank domain produces `400`, while
  a non-loopback peer or any forwarding header produces `401`.
- **A proxied public request reaches the same app:** keep the forwarding-header
  rejection and add a proxy path block or a dedicated loopback-only endpoint.
- **A second `enable_caddy_tls!` call does not change behavior:** this is
  intentional idempotency; configure the endpoint and block on the first call.
