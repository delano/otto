# Forwarded host authority

Reverse proxies use forwarding headers to report the original request's host,
scheme, and port. Rack reads these values before it falls back to the request's
`Host` header and direct connection details. Without a trust boundary, a client
can send `X-Forwarded-Host` or an RFC 7239 `Forwarded` header and choose the host
that the application believes it serves.

This affects any value derived from `request.host`, `request.scheme`,
`request.ssl?`, or `request.port`, including redirect targets, generated links,
WebAuthn `rp_id`, OmniAuth `redirect_uri`, mailer base URLs, secure-cookie
decisions, and mounted Rack applications that build absolute URLs.

Otto uses the proxy trust configured for client IP resolution to decide whether
Rack may also use forwarded host, scheme, and port values.

> [!WARNING]
> Omitting proxy trust does not reject forwarded authority. Otto leaves the
> headers intact for compatibility, and Rack applies its own process-global
> policy. Choose an explicit trust posture before serving requests whenever
> application behavior depends on these request values.

## Choose a trust posture

| Deployment | Configuration | Result |
| --- | --- | --- |
| The application is directly exposed and should trust no proxy | `trusted_proxies: :none` | Otto strips forwarded host, scheme, and port carriers from every request. |
| Proxy addresses can be enumerated | `trusted_proxies: [...]` | Otto keeps the carriers only when `REMOTE_ADDR` matches a configured proxy. |
| Proxy addresses cannot be enumerated, but the hop count is fixed | `trusted_proxy_depth: N` | Otto trusts the carriers on every request. The application origin must accept traffic only from the proxy tier. |
| Another layer owns the trust decision | Leave proxy trust unconfigured | Otto leaves the carriers unchanged and makes no trust assertion. |

For a directly exposed application:

```ruby
otto = Otto.new('routes', trusted_proxies: :none)
```

For an application behind proxies whose addresses are known:

```ruby
otto = Otto.new(
  'routes',
  trusted_proxies: ['10.0.0.0/8', '192.0.2.0/24']
)
```

Use depth mode only when the proxy addresses cannot be listed and the number of
proxy hops is fixed:

```ruby
otto = Otto.new('routes', trusted_proxy_depth: 1)
```

Depth mode treats every connecting peer as trusted. Before enabling it, prevent
direct access to the application origin with private networking, firewall or
security-group rules, or an equivalent control. Otherwise, a client can submit
forwarded host, scheme, port, and IP values directly.

Configure these options before the first request, when Otto freezes its
configuration.

## How Otto handles each trust state

The decision is made by `IPPrivacyMiddleware` from the connecting peer
(`REMOTE_ADDR`) before any masking, and recorded in
`env['otto.via_trusted_proxy']`.

| Trust state | `otto.via_trusted_proxy` | Forwarded host, scheme, and port carriers |
| --- | --- | --- |
| `REMOTE_ADDR` matches a configured trusted-proxy CIDR | `true` | Kept. When privacy masking applies, `Forwarded` keeps its `proto=`, `host=`, and `by=` fields while its `for=` value is replaced with the masked IP. |
| Depth mode is enabled | `true` for every peer | Kept, subject to the same privacy masking. |
| Proxy trust is configured, but the peer does not match a configured CIDR | `false` | Deleted. |
| `trusted_proxies: :none` is configured | `false` for every peer | Deleted. |
| Proxy trust is not configured | absent | Left unchanged. Otto makes no trust assertion, so Rack may apply its own policy. |

The deleted keys are `HTTP_FORWARDED`, `HTTP_X_FORWARDED_HOST`,
`HTTP_X_FORWARDED_PROTO`, `HTTP_X_FORWARDED_SCHEME`, `HTTP_X_FORWARDED_SSL`,
and `HTTP_X_FORWARDED_PORT`. `X-Forwarded-For` is not deleted on this path;
Otto's own client IP resolution already ignores it from an untrusted peer, and a
masking privacy profile rewrites it separately. With IP privacy disabled the
header reaches the application intact, and `Rack::Request#ip` returns its value
whenever `REMOTE_ADDR` is private or loopback. Read `env['otto.client_ip']`
rather than `Rack::Request#ip`, and configure any mounted gem that reads
`request.ip` (for example `Rack::Attack`) accordingly.

The absent `otto.via_trusted_proxy` key is intentional. It means the operator
made no proxy-trust assertion, so downstream consumers may apply their own
heuristics. This preserves compatibility for applications that already run
behind a proxy without configuring Otto's trust controls.

## Direct exposure: trust no proxy

Use `trusted_proxies: :none` when clients connect directly to the application
and no reverse proxy should influence request authority. This explicit assertion
is different from omitting `trusted_proxies`. The String spelling `'none'` (any
case) is accepted too, for YAML- or environment-driven configuration.

You can also make the assertion after construction, but before the first
request:

```ruby
otto.trust_no_proxies!
```

The same operation is available through the security configurator and the
underlying security configuration:

```ruby
otto.security.trust_no_proxies!
otto.security_config.trust_no_proxies!
```

Under this assertion:

- `env['otto.via_trusted_proxy']` is `false` for every peer;
- client IP resolution ignores forwarded chains and uses `REMOTE_ADDR`;
- forwarded host, scheme, and port carriers are stripped;
- `Rack::Request#host` resolves from the `Host` header; and
- trusted geo headers remain disabled because they require enumerated
  trusted-proxy CIDRs.

Loopback is not special-cased. A reverse proxy running on `127.0.0.1` in front
of the application is an untrusted peer under this assertion and its forwarded
headers are stripped. Use `add_trusted_proxy('127.0.0.1')` for that deployment
instead. The separate `env['otto.peer_loopback']` signal is derived from the raw
peer and is unaffected, as is `env['otto.peer_relayed']`, which records whether
any relay marker header was present before the carriers were stripped so
`Otto::CaddyTLS::LocalhostGuard` still refuses a relayed request.

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

## Choose the forwarding family for depth mode

`Rack::Request.forwarded_priority` is a process-wide setting that determines
which forwarding family Rack reads: `X-Forwarded-*`, RFC 7239 `Forwarded`, or
both. Otto pins it to the family selected by `trusted_proxy_header` so Otto and
Rack interpret the same request metadata.

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
on the family. Neither can block a later explicit choice, unless it also names
`trusted_proxy_header` explicitly: naming the header is always a claim, even
under `trusted_proxies: :none`.

`trusted_proxy_header` accepts `X-Forwarded-For` (the default), `Forwarded`, or
`Both`. When configuring proxy trust, `Forwarded` and `Both` require depth mode.
CIDR filter mode resolves client IPs from `X-Forwarded-For`, so a non-default
family would make Rack read a header that Otto ignores:

```text
Cannot configure trusted_proxy_header 'Forwarded' or 'Both' together with
trusted_proxies (CIDR filter mode): CIDR-walk resolves client IPs from
X-Forwarded-For only. Use trusted_proxy_depth (count mode) to read the RFC 7239
Forwarded header.
```

Use `trusted_proxy_depth` when the deployment requires RFC 7239 `Forwarded`.
Remember that depth mode also requires origin lockdown because it trusts every
connecting peer.

## Place the middleware before other request consumers

Otto performs this filtering in `IPPrivacyMiddleware`, which it installs first
in its own stack. Downstream middleware, mounted applications, and handlers see
the filtered environment.

If middleware outside the Otto application reads the request first, mount
`IPPrivacyMiddleware` ahead of it in the common Rack stack. Pass the
application's security configuration, as shown in
[Privacy-preserving request data](privacy.md#middleware-placement). Without that
configuration, the outer middleware instance applies defaults and makes no
trust decision, so forwarded authority reaches earlier middleware unchanged.
