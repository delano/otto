# Caddy on-demand TLS

`Otto::CaddyTLS` provides the permission endpoint Caddy calls before obtaining
or loading a certificate for a domain. Otto owns the route, parameter-shape
checks, access guard, response semantics, and fail-closed behavior. The
application supplies one decision block: whether the requested domain is
allowed.

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

The block receives the stripped `domain` string from `?domain=`. Otto checks
that the parameter is a non-empty string, but does not validate DNS syntax,
lowercase the value, remove a trailing dot, or convert internationalized names.
Perform any application-specific hostname normalization and validation in the
block before querying domain data. A truthy result returns `200 OK`; a falsey
result returns `403 Forbidden`. An exception raised by the block is logged and
treated as a denial.

The default endpoint is `/_caddy/tls-permission`. No entry in the routes file is
required. Enabling without a block raises `ArgumentError`, and repeated enable
calls are idempotent: the first configuration and decision block remain active.

## Configure Caddy

`on_demand_tls` is a global Caddy option, and configuring its permission check
does not enable on-demand TLS for a site. A complete minimal configuration is:

```caddyfile
{
  on_demand_tls {
    permission http http://127.0.0.1:PORT/_caddy/tls-permission
  }
}

https:// {
  tls {
    on_demand
  }

  reverse_proxy 127.0.0.1:APP_PORT
}
```

Replace `PORT` with the loopback port serving the Otto permission endpoint and
`APP_PORT` with the application port receiving normal traffic. If the same Otto
app serves both, the ports may be the same.

Caddy also documents `ask` as a backwards-compatible shortcut for the built-in
HTTP permission module:

```caddyfile
{
  on_demand_tls {
    ask http://127.0.0.1:PORT/_caddy/tls-permission
  }
}
```

Both forms append `?domain=<host>` and treat a non-`2xx` response as a denial.
Validate the chosen form with the Caddy version you deploy:

```sh
caddy adapt --config Caddyfile --adapter caddyfile
```

See Caddy's [`on_demand_tls` documentation](https://caddyserver.com/docs/caddyfile/options#on-demand-tls)
for the current module syntax and deployment requirements.

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
2. no non-empty forwarding header indicates that the request was relayed
   through another proxy.

The guard authenticates the original peer, not the resolved client address in
`REMOTE_ADDR` or `otto.client_ip`. This matters when a loopback proxy is also a
trusted proxy: forwarded headers must not be able to turn a remote caller into a
local one. The guard rejects the endpoint request when any of these headers has a
non-empty value:

- `X-Forwarded-For`
- `X-Real-IP`
- `X-Client-IP`
- `Forwarded`
- `X-Forwarded-Host`
- `X-Forwarded-Proto`
- `X-Forwarded-Scheme`
- `X-Forwarded-SSL`
- `X-Forwarded-Port`

The list is the full set (`Otto::Utils::RELAY_MARKER_HEADERS`): every forwarding
carrier Otto knows, including the authority headers, not only the client-IP
carriers. A front server that adds any of them to the permission request, even
one that only records the scheme or port, turns the call into a relayed request
and the guard returns `401`. Configure the permission endpoint so the request
reaches Otto without forwarding headers.

The guard is path-scoped. Other application routes pass through it unchanged,
and path normalization is shared with the router so encoded or trailing-slash
variants cannot bypass the check.

This protection assumes the Rack server leaves the actual connecting peer in
`REMOTE_ADDR` and that no earlier proxy or middleware removes relay-marker
headers before Otto records them. If PROXY protocol or an outer middleware
rewrites either input, verify that Otto still receives an authentic peer address
and the original forwarding markers. The strongest boundary is a dedicated
loopback-only listener.

## Deployment topology

The recommended deployment is a small Otto app bound to a loopback-only port on
the same host as Caddy:

```text
Caddy -- loopback --> Otto CaddyTLS endpoint -- authenticated app channel --> domain data
```

Caddy expects this decision in a few milliseconds. Prefer an indexed local
lookup or in-process cache. If the permission app must call an internal service,
use a short timeout and cache the result: an exception or timeout that reaches
the block's fail-closed wrapper becomes a denial and can fail the TLS handshake.
That data channel is an application responsibility; it does not widen the Caddy
endpoint's network trust boundary.

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
  a non-loopback peer or any non-empty forwarding header produces `401`.
- **A proxied public request reaches the same app:** keep the forwarding-header
  rejection and add a proxy path block or a dedicated loopback-only endpoint.
- **A second `enable_caddy_tls!` call does not change behavior:** this is
  intentional idempotency; configure the endpoint and block on the first call.
