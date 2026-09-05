# Forwarded host authority

`Rack::Request#host` is derived from forwarded headers before it falls back to
the `Host` header. Rack applies its process-global forwarding priority and does
not consult Otto's proxy trust decision, so on a bare Rack stack any client can
send `X-Forwarded-Host` or an RFC 7239 `Forwarded` header and choose the host
the application believes it is serving.

Everything built on `request.host` inherits that choice: redirect targets,
generated links, WebAuthn `rp_id`, OmniAuth `redirect_uri`, mailer base URLs,
and any mounted gem that builds absolute URLs. The same applies to
`request.scheme`, `request.ssl?`, and `request.port`, which come from the same
carriers. `Rack::Session` gates its `Secure` cookie flag on `ssl?`.

Otto gates those carriers on the trusted-proxy trust signal it already computes
for client IP resolution.

## What Otto does per trust state

The decision is made by `IPPrivacyMiddleware` from the connecting peer
(`REMOTE_ADDR`) before any masking, and recorded in
`env['otto.via_trusted_proxy']`.

| Trust state | `otto.via_trusted_proxy` | Forwarded host, proto, scheme, ssl, port carriers |
| --- | --- | --- |
| Peer matches a configured trusted-proxy CIDR, or any peer under depth mode | `true` | Kept. `Forwarded` keeps its `proto=`, `host=`, and `by=` fields; the `for=` value is redacted to the masked IP when privacy masking applies. |
| Proxy trust is configured and this peer fails it | `false` | Deleted. |
| Nothing about proxy trust is configured | absent | Left to Rack. Otto asserts nothing. |
| Operator explicitly asserted that no proxy is trusted | `false` for every peer | Deleted. |

The deleted keys are `HTTP_FORWARDED`, `HTTP_X_FORWARDED_HOST`,
`HTTP_X_FORWARDED_PROTO`, `HTTP_X_FORWARDED_SCHEME`, `HTTP_X_FORWARDED_SSL`,
and `HTTP_X_FORWARDED_PORT`. `X-Forwarded-For` is not deleted on this path;
Otto's own client IP resolution already ignores it from an untrusted peer, and
the privacy pipeline masks it separately.

An application that configures no proxy trust at all keeps the third row's
behavior deliberately. The absent key is a contract: it means the operator
asserted nothing, and downstream consumers may apply their own heuristics.
Changing that default would break host resolution for operators who run behind
a proxy without configuring trust.

## Asserting that no proxy is trusted

To get the stripping behavior on a directly exposed application, make the
assertion explicit:

```ruby
otto = Otto.new('routes', trusted_proxies: :none)
```

Post-construction, before the first request freezes configuration:

```ruby
otto.trust_no_proxies!
```

The same call exists on the security config and the configurator:

```ruby
config.trust_no_proxies!
```

Under this assertion `env['otto.via_trusted_proxy']` is `false` for every peer,
client IP resolution ignores forwarded chains and uses `REMOTE_ADDR`, the
forwarded host, scheme, and port carriers are stripped, and `Rack::Request#host`
resolves only from the `Host` header. Trusted geo headers stay off, since they
require enumerated trusted-proxy CIDRs.

Loopback is not special-cased. A reverse proxy running on `127.0.0.1` in front
of the application is an untrusted peer under this assertion and its forwarded
headers are stripped. Use `add_trusted_proxy('127.0.0.1')` for that deployment
instead. The separate `env['otto.peer_loopback']` signal is derived from the raw
peer and is unaffected.

The assertion is mutually exclusive with an actual trust grant. Combining it
with trusted-proxy CIDRs or a depth of 1 or more raises at configuration time:

```text
Cannot combine trusted_proxies: :none (trust no proxy) with trusted_proxies
CIDRs or trusted_proxy_depth >= 1. Assert :none OR grant trust, not both.
```

## Why the whole Forwarded header is removed

For an untrusted peer Otto deletes `Forwarded` entirely rather than editing out
its `host=` field. Editing would require Otto to parse RFC 7239 itself, and a
parser that disagrees with Rack's on quoting can let a `host=` survive the edit.
A value such as `for=a"b;host=evil` is enough to produce that disagreement.
Deletion has no such failure mode. On this path Otto reads nothing from the
header itself, so nothing is lost.

## The process-global forwarding family

`Rack::Request.forwarded_priority` is a single process-wide setting that decides
which forwarded family Rack reads: `X-Forwarded-*`, RFC 7239 `Forwarded`, or
both. Otto pins it to the family selected by `trusted_proxy_header` so Otto's
view of the request and Rack's cannot disagree.

```ruby
otto = Otto.new(
  'routes',
  trusted_proxy_depth: 1,
  trusted_proxy_header: 'Forwarded'  # or 'X-Forwarded-For' (default), or 'Both'
)
```

Because the setting is process-wide, two Otto applications mounted in one
process that both resolve proxied requests must agree. The later one raises:

```text
Cannot use forwarding family %s (trusted_proxy_header) because another Otto
application in this process already uses %s. Rack's forwarded host, port,
scheme, and IP policy is process-global, so every Otto application in one
process that resolves proxied requests must use the same forwarding family.
```

The two placeholders are the requested family and the already committed one.

An application that configures no proxy trust, and one that asserts
`trusted_proxies: :none`, read no forwarded chain and therefore stake no claim
on the family. Neither can block a later explicit choice.

A non-default family cannot be combined with CIDR filter mode. Otto's CIDR walk
resolves client IPs from `X-Forwarded-For` only, so pinning Rack to `Forwarded`
or `Both` would make Rack read a header Otto ignores:

```text
Cannot configure trusted_proxy_header 'Forwarded' or 'Both' together with
trusted_proxies (CIDR filter mode): CIDR-walk resolves client IPs from
X-Forwarded-For only. Use trusted_proxy_depth (count mode) to read the RFC 7239
Forwarded header.
```

Use `trusted_proxy_depth` (count mode) when the deployment needs the RFC 7239
header.

## Middleware ordering

The scrub happens in `IPPrivacyMiddleware`, which Otto installs first in its own
stack. Downstream middleware, mounted applications, and handler code all see the
already scrubbed environment.

If middleware outside the Otto application inspects the request first, mount the
privacy middleware in the common stack ahead of it and pass the application's
security config, as described in
[Privacy-preserving request data](privacy.md#middleware-placement). Without the
config, the outer instance applies defaults and makes no trust decision, so the
carriers reach the outer middleware intact.
