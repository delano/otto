# Otto — Caddy on-demand TLS demo

This example demonstrates `Otto::CaddyTLS`, Otto's integration for the **Caddy
on-demand TLS permission endpoint**. When Caddy serves TLS for a hostname it has
no certificate for, it asks the backend "may I obtain a certificate for this
domain?". This endpoint answers that question.

One endpoint serves **both** the deprecated `ask` directive and its replacement,
the `permission http` module — their HTTP contract is identical, so migration is
config-only on Caddy's side.

## What you'll learn

- How to enable a modular network-service integration with one call
  (`enable_caddy_tls!`)
- How the app supplies just the domain decision while Otto owns the HTTP ceremony
- How the localhost guard authenticates the raw socket peer (secure by default)
- How the permission endpoint coexists with a normal Otto app

## Run it

```sh
cd examples/caddy_tls_demo
rackup config.ru        # serves on http://localhost:9292
```

## Try it

The demo allowlists `verified.example.com` and `tenant-a.example.com` (see
`app.rb`). Requests must come from loopback (rackup binds localhost, so `curl`
from the same host works).

```sh
# Allowed domain  -> 200 OK
curl -i "http://127.0.0.1:9292/_caddy/tls-permission?domain=verified.example.com"

# Unknown domain  -> 403 Forbidden
curl -i "http://127.0.0.1:9292/_caddy/tls-permission?domain=nope.example.com"

# Missing domain  -> 400 Bad Request
curl -i "http://127.0.0.1:9292/_caddy/tls-permission"

# The app's own routes are unaffected by the guard
curl -i "http://127.0.0.1:9292/health"
```

A non-loopback caller receives `401 Unauthorized` — the guard reads the raw TCP
peer, so a spoofed `X-Forwarded-For: 127.0.0.1` does **not** help.

## Wire up Caddy

```caddyfile
{
  on_demand_tls {
    permission http { endpoint http://127.0.0.1:9292/_caddy/tls-permission }
  }
}

https:// {
  tls {
    on_demand
  }
  reverse_proxy 127.0.0.1:9292
}
```

Legacy/deprecated form (same endpoint, same contract):

```caddyfile
on_demand_tls { ask http://127.0.0.1:9292/_caddy/tls-permission }
```

## Production deployment (including cross-host)

The guard is loopback-only, and stays that way even when Caddy and your app run on
**different hosts**. Run the permission endpoint as a tiny app **on the same host
as Caddy** — see [`standalone.ru`](standalone.ru):

```
[ Caddy host ]                          [ App / data host(s) ]
  Caddy ──loopback──▶ tiny Otto app ──(your own channel)──▶ real domain data
        (127.0.0.1)     enable_caddy_tls! { |domain| ... }
```

The Caddy → endpoint hop stays loopback (unspoofable); the decision block reaches
your real data over whatever channel your app already trusts. Two more defenses:

- The guard **rejects any request carrying a forwarding header** (`X-Forwarded-For`
  et al.). Caddy's direct permission call has none; a request *relayed through* a
  proxy does — so even if you accidentally mount this inside a public proxied app,
  proxied requests are denied despite arriving from the loopback proxy.
- If you do mount it inside a proxied app, also block the path at the proxy
  (Caddy's `on_demand_tls` call bypasses its own route rules, so this is safe):

  ```caddyfile
  @tls_permission path /_caddy/tls-permission
  respond @tls_permission 404
  ```

See [`docs/reverse-proxy-network-services.md`](../../docs/reverse-proxy-network-services.md).
