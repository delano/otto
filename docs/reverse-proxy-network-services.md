# Reverse-proxy / network-service integrations

**Status:** shipped pilot (issue [#175](https://github.com/delano/otto/issues/175))
**Ships:** `Otto::CaddyTLS` — Caddy on-demand TLS permission endpoint
**Date:** 2026-07

This document captures the design exploration for how Otto absorbs
*network-service integrations* — small, optional, turnkey endpoints where an
external network component (a reverse proxy, a TLS layer, a monitoring probe)
speaks a fixed HTTP contract to the app, and the app supplies a tiny decision or
handler while Otto owns all the HTTP ceremony.

The pilot absorbs OneTimeSecret's "Internal ACME" app — the endpoint Caddy calls
to decide whether to obtain a certificate on demand — into a reusable Otto
primitive, decoupled from any application's domain model.

> **Namespace note (resolved during review — see §4 and §7).** This work first
> shipped under an umbrella `Otto::Services` namespace, on the assumption that CSP
> reporting ([#174](https://github.com/delano/otto/issues/174)) would be its
> second tenant. When #174 actually landed it chose `Otto::Security::CSP` — it is
> the *receiving half* of Otto's own CSP support and belongs beside the emitting
> half (`Otto::Security::Config`), not in a generic bucket. With its presumed
> second tenant placed elsewhere, the umbrella had exactly one occupant, so it was
> collapsed to a feature-named `Otto::CaddyTLS`, matching the existing `Otto::MCP`
> precedent. "Making space" turned out to mean *a documented pattern plus shared
> primitives in `Otto::Core`* — not a shared namespace module.

---

## 1. Problem & goal

Apps that sit behind a reverse proxy repeatedly hand-roll the same small
endpoints:

- **Caddy on-demand TLS** asks the backend "may I get a cert for this host?"
  before issuing. The backend must parse `?domain=`, return `200`/non-`2xx`,
  restrict the caller to localhost, and fail closed on errors.
- **CSP violation reporting** ([#174](https://github.com/delano/otto/issues/174))
  receives browser-posted violation reports, parsing two formats, bypassing
  CSRF, capping the body, and never raising.

Each app rebuilds this ceremony — routing, method/size limits, response
semantics, security guard, fail-safe behavior — around one app-specific decision.
That repetition is exactly the kind of thing Otto already removes for MCP.

**Goal:** *make space* — establish the shared pattern for these integrations and
prove it with one concrete, well-decoupled pilot (Caddy on-demand TLS).
Explicitly **not** a goal: build a framework, a registry, or the CSP endpoint now.
The pattern should make CSP #174 a straightforward later sibling without being
designed around it.

## 2. The pattern, and its two instances

| Aspect | Caddy on-demand TLS | CSP reporting (#174) |
|---|---|---|
| Direction | proxy → app (control plane) | browser → app (telemetry) |
| Verb / surface | `GET ?domain=` | `POST` JSON body |
| App's job | decide allow/deny for a domain | receive a normalized report |
| Otto's job | route, guard, fail-closed, `200`/`403` | intercept, CSRF-bypass, size-cap, parse, `204` |
| Caller trust | **loopback only** (co-located proxy) | **public** (any browser) |
| Coupling point | one decision block | one callback |
| Ties to an Otto subsystem | none (bridge to an external service) | **yes** — it's the receiving half of Otto's CSP header support |
| Home | `Otto::CaddyTLS` (top-level, like `Otto::MCP`) | `Otto::Security::CSP` (beside CSP emission) |

The common shape is *"a fixed external HTTP contract, an app-supplied
decision/handler, and Otto owning the ceremony."* That shape is the pattern worth
establishing. But the two instances differ on nearly everything else — trust
model, verb, consumer-API shape, and, decisively, **their relationship to existing
Otto subsystems**. Caddy TLS is a bridge to an external service (Caddy) and stands
alone; CSP reporting is one half of a capability Otto already owns. That is why
they get *separate feature-named homes* rather than a shared umbrella — and why the
only thing genuinely worth extracting up front is the reusable *mechanism* each
needs (the localhost guard here; the `:outermost` middleware position there),
not a namespace to file them both under.

## 3. Options considered

Four architectures were explored (a design panel generated and adversarially
critiqued each):

1. **MCP-style route-based primitive.** `enable_caddy_tls! { |domain| … }` lazily
   builds a small `Server` that registers a `GET` route programmatically (like
   `/_mcp`) and installs a localhost guard. *Pro:* mirrors the proven MCP
   precedent exactly; lowest review risk; turnkey. *Con:* one new namespace.
2. **Callback + config, interceptor middleware (CSP #174 style).** Configuration
   is data (endpoint + callback); a Rack middleware intercepts the path and
   short-circuits with `200`/`403`, no route entry. *Pro:* symmetric with how
   #174 configures. *Con (fatal for this endpoint):* a short-circuiting
   interceptor that sits ahead of the guard in the stack answers **before** the
   guard runs — a fail-**open** exposure of the cert gate to remote clients.
   (This is why CSP, which is *meant* to be public, correctly uses the interceptor
   pattern, and Caddy TLS, which must be gated, correctly does not.)
3. **Minimalist provided handler class.** Otto ships a handler you reference in
   `routes.txt` plus a guard you `use` yourself. *Pro:* least magic. *Con:* the
   operator must remember to wire the guard separately — a "forgot the guard"
   footgun on a security-critical endpoint.
4. **General network-services registry/base.** A shared `Endpoint` base or
   registry that Caddy and CSP both plug into. *Con:* premature abstraction — only
   one consumer differs (the guard), which doesn't justify a base class (YAGNI).
   (#174 later confirmed this: it shared *no* base with Caddy TLS.)

## 4. Recommendation

**Ship option 1 (MCP-style route-based primitive) as a top-level, feature-named
module `Otto::CaddyTLS`, with the localhost guard authenticating the raw TCP
peer.**

```
Otto::CaddyTLS                     # opt-in integration, sibling to Otto::MCP
├── CaddyTLS::Core                 # mixin on Otto: enable_caddy_tls!, caddy_tls_enabled?
├── CaddyTLS::LocalhostGuard       # opt-in, raw-peer loopback guard middleware
├── CaddyTLS::Server               # enable!/enabled?/permit? (fail-closed), route+guard registration
└── CaddyTLS::PermissionHandler    # class-method handler: ?domain= → 400/200/403
```

Rejected: the interceptor (fail-open risk here), routes.txt-first (guard footgun),
and the registry/base (premature).

**Why a feature-named module, not an `Otto::Services` umbrella.** The umbrella was
the initial choice, justified by CSP #174 being its second tenant. That premise did
not hold (§7): #174 shipped as `Otto::Security::CSP`. Three signals in the codebase
all point to a feature-named home instead:

- **`Otto::MCP`** — Otto's existing external-system integration is a *top-level,
  protocol-named* namespace with `enable_mcp!`. Caddy TLS is the same shape.
- **`Otto::Security::CSP`** — even a security *sub-feature* is named for itself and
  nested under the subsystem it belongs to, not dropped in a generic bucket.
- **Shared mechanism lives in `Otto::Core`** — the one primitive CSP genuinely
  reused (the `:outermost` middleware position) was added to
  `lib/otto/core/middleware_stack.rb`, not to any "services" module. Otto's
  instinct is: promote shared code to core, name features for themselves.

None of these support a generic `Otto::Services` drawer, so it was collapsed to
`Otto::CaddyTLS`. `LocalhostGuard` lives under `Otto::CaddyTLS` while it has a
single consumer; if a second internal-only integration ever needs it, promote it to
a shared home then, shaped by two real examples.

### Public API

```ruby
otto = Otto.new('routes.txt')

otto.enable_caddy_tls! do |domain|
  # The ONLY coupling point. Return truthy => 200 (issue cert), falsy => 403 (deny).
  # `domain` is the only input. Any exception here is caught and denies (fail-closed).
  MyApp::CustomDomain.verified?(domain)
end

otto.caddy_tls_enabled? # => true
```

Defaults: `endpoint: '/_caddy/tls-permission'`, `localhost_only: true`. The route
is registered programmatically (like `/_mcp`) — no `routes.txt` entry required.
Enabling without a block raises `ArgumentError` (there is no allow-all default).
All setup runs through `ensure_not_frozen!`, so it must happen before the first
request, and re-enabling is idempotent (the route/guard are never duplicated).

### Caddyfile (config-only; both directives, identical contract)

```caddyfile
on_demand_tls {
  permission http { endpoint http://127.0.0.1:PORT/_caddy/tls-permission }
}

# Legacy / deprecated — same endpoint, same HTTP contract:
on_demand_tls { ask http://127.0.0.1:PORT/_caddy/tls-permission }
```

## 5. Security model

The endpoint gates certificate issuance, so the **allow** path must be
un-trickable; the **deny** path is naturally safe (Caddy treats any non-`2xx` as
deny). Everything fails closed.

### 5.1 Authenticate the *raw* peer, not the resolved client IP

This is the load-bearing decision, and it corrects the obvious-but-wrong first
instinct (which every initial design in the panel made).

`Otto::CaddyTLS::LocalhostGuard` reads the **original `env['REMOTE_ADDR']`** — the
TCP socket peer — and runs **before** `IPPrivacyMiddleware` rewrites `REMOTE_ADDR`
from forwarded headers. Because the guard is installed via `Otto#use` (appended,
therefore *outermost* in Otto's `reduce`-built stack) and `IPPrivacyMiddleware` is
pinned *innermost*, the guard provably inspects the true socket peer regardless of
when `enable_caddy_tls!` is called.

Reading Otto's resolved `otto.client_ip` (or the rewritten `REMOTE_ADDR`) would be
**exploitable**: `Otto::Utils.resolve_client_ip` honors `X-Forwarded-For` when the
peer is a *trusted proxy*, and a co-located Caddy on loopback is itself a natural
trusted proxy. An attacker who could route to the endpoint through it and send
`X-Forwarded-For: 127.0.0.1` would be resolved to loopback and let in.
Authenticating the raw peer removes forwarded headers from the trust decision
entirely. (See `spec/otto/caddy_tls/localhost_guard_spec.rb`, "spoofing
resistance".)

### 5.2 Reject relayed requests (forwarding headers)

A direct call is loopback peer **and** *no forwarding headers*. Caddy's on-demand
permission request is a direct backend call and carries none; a request that was
**relayed through a reverse proxy** carries `X-Forwarded-For` (or `X-Real-IP`,
`X-Client-IP`, `Forwarded`). The guard denies any request to the endpoint that
carries one, even if its socket peer is loopback.

This is what makes the endpoint safe against the "accidentally bolted onto an
existing app" mistake: if the endpoint is mounted inside a public app behind a
proxy that connects to the backend over loopback, *every* proxied user request has
a loopback peer — but it also carries a forwarding header, so it is denied. Only
the proxy's direct control-plane call (loopback peer, no forwarding header) is
allowed.

### 5.3 Correct loopback detection

`IPAddr.new(remote_addr).native.loopback?`, wrapped `rescue … => false`:

- `.native` folds IPv4-mapped IPv6 (`::ffff:127.0.0.1`, which dual-stack servers
  commonly present) — plain `#loopback?` returns **false** for the mapped form and
  would wrongly reject legitimate traffic.
- Blank, malformed, or `:port`-suffixed values (a non-standard `REMOTE_ADDR`) fail
  closed to `401` rather than raising on Caddy's TLS-handshake hot path.

### 5.4 Path-scoped, bypass-resistant

The guard only enforces loopback for its own endpoint; every other route passes
through untouched. It normalizes `PATH_INFO` (URL-unescape, scrub invalid UTF-8
bytes, strip trailing slashes) **exactly as the router does**, so a percent-encoded
(`…permissio%6e`), invalid-byte, or trailing-slash variant that the router would
still route cannot slip past by normalizing differently in the guard than at
dispatch.

### 5.5 Fail-closed everywhere

- The app block is wrapped by `Server#permit?`: `nil`, `false`, or any
  `StandardError` denies (`403`) and logs.
- Blank/missing `domain` returns `400` before the block is consulted.
- Only `?domain=` reaches the decision — no other query parameter. This preserves
  the downstream removal of `check_verification` (local processes must not bypass
  DNS verification via the query string).
- `enable_caddy_tls!` with no block raises rather than defaulting to allow-all.

### 5.6 Deployment: co-locate the endpoint with Caddy

The guard is **loopback-only by design**, and it stays that way even when Caddy
and the application run on **different hosts**. The recommended topology is to run
the permission endpoint as a tiny Otto app **on the same host as Caddy** — see
`examples/caddy_tls_demo/standalone.ru`:

```
[ Caddy host ]                         [ App / data host(s) ]
  Caddy ──loopback──▶ tiny Otto app ──(your own authenticated channel)──▶ data
        (127.0.0.1)     enable_caddy_tls! { |domain| ... }
```

The Caddy → endpoint hop is always loopback (secure, unspoofable). The endpoint's
decision block is app-supplied, so it reaches the real domain data over whatever
channel the app already trusts (an internal API call, a shared database, a cache).
This keeps the *authentication* boundary simple and strong (loopback) while the
*data* lookup crosses hosts however the app likes.

Rejected alternative: widening the guard to a configurable trusted-source IP
allowlist so Caddy could call cross-host directly. It trades an unspoofable
boundary (loopback) for a spoofable one (source IP on a shared network) and adds
configuration surface, for no capability the co-location topology doesn't already
provide. Loopback-only + co-location is the better overall design.

Additional layers (defense in depth):

- **Dedicated loopback port.** Bind the endpoint app on `127.0.0.1:PORT` serving
  *only* the permission route, so it is unreachable from off-host by construction.
- **Proxy path block.** If you *do* mount the endpoint inside a proxied app, also
  block the path at the proxy. Caddy's `on_demand_tls` call bypasses Caddy's own
  route rules, so blocking the public path does not affect certificate validation:

  ```caddyfile
  @tls_permission path /_caddy/tls-permission
  respond @tls_permission 404
  ```

## 6. Absorbing the OneTimeSecret "Internal ACME" app

The behavior maps 1:1, decoupled and hardened:

| OneTimeSecret | Otto pilot |
|---|---|
| `AskHandler.call` (`?domain=` → 400/200/403, `text/plain` `OK`/`Forbidden`) | `CaddyTLS::PermissionHandler.handle` (identical) |
| `LocalhostOnly` (trusts resolved `REMOTE_ADDR`, plain `#loopback?`) | `CaddyTLS::LocalhostGuard` (raw peer + reject forwarding headers, `.native.loopback?`, fail-closed, router-equivalent path scoping) |
| `Application.domain_allowed?` → `CustomDomain…ready?` (the coupling) | app-supplied `enable_caddy_tls!` block |
| `domain_allowed?` `rescue => false` | absorbed into `Server#permit?` so every consumer inherits it |
| `check_verification` removed from HTTP surface | preserved: only `?domain=` is read |

## 7. How CSP reporting (#174) actually landed — and what it taught us

This is the part that validated (and corrected) the design. CSP reporting shipped
**not** as a second tenant of this namespace but as `Otto::Security::CSP`
(`Parser`, `Report`, `ReportMiddleware`), enabled via
`enable_csp_reporting!(report_uri) { |report| … }` on `Otto::Security::Core`. It is
a public, unauthenticated Rack middleware pinned `:outermost`, always answers
`204`, size-caps the body, and dispatches each parsed report through a
fire-and-forget callback held on `Otto::Security::Config`.

What that outcome confirms:

- **The pattern is real.** CSP is the same *shape* — a fixed external HTTP
  contract, an app-supplied handler, Otto owning the ceremony — so the pilot did
  generalize a genuine recurring need.
- **The shared-namespace hypothesis was wrong.** CSP belongs beside Otto's CSP
  *emission* (`report-uri` directive, nonce policy) in `Otto::Security`; it shares
  `csp_report_uri` and the violation callback with header generation. Filing it in
  a generic `Otto::Services` would have severed it from the code it is one half of.
  A network-service integration goes wherever its *domain* is — `Otto::Security` for
  CSP, its own module for the Caddy bridge — not into a bucket named after the
  mechanism.
- **What's actually shared is mechanism, and it lives in core.** The one thing both
  features needed was a way to run a middleware ahead of CSRF/auth. That became the
  generic `:outermost` position in `Otto::Core`'s middleware stack — reusable by
  any integration, owned by none.
- **The guard is correctly *not* shared.** CSP reports come from browsers, so CSP
  opts out of any localhost guard and instead leans on content-type gating, a size
  cap, and Otto's rate limiting. That opt-out is exactly why `LocalhostGuard` is a
  standalone building block rather than baked into a base class — and it is the
  post-hoc comparison #174 asked for: a modular CSP endpoint differs from a
  hand-built one only in that the enable/callback/route plumbing is conventionalized.

## 8. Decisions

Resolved during review:

- **Namespace:** `Otto::CaddyTLS` (top-level, feature-named, mirroring
  `Otto::MCP`). The earlier `Otto::Services` umbrella was collapsed once #174
  chose `Otto::Security::CSP`, leaving the umbrella with a single tenant (§4, §7).
- **Loopback-only, even cross-host.** The endpoint stays loopback-only; when Caddy
  and the app run on different hosts, co-locate the tiny permission app with Caddy
  (§5.6). Chosen over a configurable trusted-source IP allowlist because loopback
  is an unspoofable boundary and co-location needs no extra config or trust.
- **API shape:** `enable_caddy_tls!` (code-side) is the primary, secure-by-default
  path — it bundles route + guard + decision so the endpoint cannot exist without
  its guard. The handler class *is* resolvable from a routes file for advanced
  users, but that split (route declared without guard) is the exact footgun we
  avoid, so it is not the documented path.
- **Multi-instance:** the handler resolves its `Server` per-request from the Otto
  instance the dispatcher binds to it (not a class-level global), so multiple Otto
  apps in one process each evaluate their own permission block.

Still the maintainer's call:

- **Default endpoint path:** `'/_caddy/tls-permission'` (`_`-prefixed like `/_mcp`).
  The absorbed app used `/api/internal/acme/ask`.
- **Guard denial status:** `401` (parity with the absorbed `LocalhostOnly`) vs
  `403`. Both are non-`2xx`, so Caddy denies either way.

## References

- Caddy on-demand TLS / permission module — https://caddyserver.com/docs/json/apps/tls/automation/on_demand/permission/http/
- Issue #175 (this work) · Issue #174 (CSP reporting, shipped as `Otto::Security::CSP`)
- Precedent: `lib/otto/mcp/` (modular protocol integration)
- Code: `lib/otto/caddy_tls/` · Specs: `spec/otto/caddy_tls/` · Example: `examples/caddy_tls_demo/`
