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

> [!WARNING]
> These settings control forwarded authority only. They do not validate the
> ordinary `Host` header. After forwarded carriers are stripped, Rack falls back
> to `Host`, which a direct client can still choose. If redirects, generated
> links, WebAuthn, OAuth, or cookie policy require a canonical host, enforce a
> host allowlist in the front server or application.

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

## How enumerated proxy trust resolves the client IP

With `trusted_proxies: [...]`, Otto reads `X-Forwarded-For` only when
`REMOTE_ADDR` matches a configured proxy. It then reads the header from the
right: starting with the entry nearest the application, it skips entries that
match a configured proxy and takes the first entry that does not as the client
IP. Entries to the left of that one are never used. If every entry matches a
configured proxy, Otto uses `REMOTE_ADDR`.

For example, with `trusted_proxies: ['10.0.0.0/8']` and a request from
`10.0.0.5` carrying `X-Forwarded-For: 198.51.100.7, 203.0.113.9, 10.0.0.9`,
the client IP is `203.0.113.9`. The `198.51.100.7` entry is whatever the client
sent.

If the walk reaches an entry that is not a valid IP address (such as `unknown`,
an empty entry, including the one a trailing comma leaves, or a range such as
`203.0.113.9/0`) before it finds one that does not match, the request has no
client IP. A proxy wrote that entry where the client belongs, and the proxy
itself is not the client. `env['otto.ip_match']` returns false for every range,
`env['otto.client_ip']` and `Otto::Request#client_ipaddress` are nil, and when
IP privacy is enabled (the `:masked` and `:anonymous` profiles) Otto deletes
`X-Forwarded-For`, `X-Real-IP` and `X-Client-IP` and removes every `for=` pair
from `Forwarded`, keeping its `proto=`, `host=` and `by=` fields (an element
left empty is dropped, and a header left empty is deleted). `REMOTE_ADDR` keeps
the proxy's address, and both `req.ip` and a plain `Rack::Request#ip` return
it, so rate limiters still have a key; see
[the privacy guide](privacy.md#default-behavior) for why.

The walk gives the right answer only when two things hold:

- **Every proxy between the client and the application is listed** in
  `trusted_proxies`, together with any address a proxy appends about itself.
  Google Cloud's external Application Load Balancer, for example, appends the
  client's address and then its forwarding rule's address, so the forwarding
  rule's address has to be listed as well as the load balancer's own ranges.
  An unlisted address is an untrusted entry: the one nearest the application
  becomes the client IP for every request through it. Rate-limit keys and
  `otto.privacy.hashed_ip` then collapse onto that address, `ip_match` tests
  it, and if it is private or loopback the request is exempt from masking.
  A CDN in front of a listed load balancer is the common case: list the CDN's
  edge ranges too.
- **Every listed proxy appends** the address it received the request from to
  `X-Forwarded-For`. nginx does this with
  `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`. A trusted
  proxy that passes the client's `X-Forwarded-For` through unchanged lets the
  client choose the rightmost entry, and with it the resolved client IP, the
  value `env['otto.ip_match']` checks, and every key derived from it.
  Configure each trusted proxy to append to the header, or to replace a
  client-supplied value with the address it observed.

Releases through 2.12.0 took the leftmost untrusted entry instead, which the
client controls behind an appending proxy. Under that walk a missing inner
proxy did not change the result for a client that sent no `X-Forwarded-For`,
so a deployment that worked on 2.12.0 can need more `trusted_proxies` entries
after upgrading.

`X-Real-IP` and `X-Client-IP` each carry one address. Otto reads them only when
`X-Forwarded-For` is absent or blank, `X-Real-IP` first and then `X-Client-IP`,
and never adds them to the `X-Forwarded-For` chain. A proxy that sets
`X-Real-IP` but passes a client's `X-Forwarded-For` through still lets that
header decide the client IP. When `X-Forwarded-For` is present and every entry
in it is a trusted proxy, Otto uses `REMOTE_ADDR`, not `X-Real-IP`. A proxy
that sets only `X-Real-IP` should also append to or replace
`X-Forwarded-For`.

## How Otto handles each trust state

The decision is made by `IPPrivacyMiddleware` from the connecting peer
(`REMOTE_ADDR`) before any masking, and recorded in
`env['otto.via_trusted_proxy']`.

| Trust state | `otto.via_trusted_proxy` | Forwarded host, scheme, and port carriers |
| --- | --- | --- |
| `REMOTE_ADDR` matches a configured trusted-proxy CIDR | `true` | Kept. When IP privacy is enabled, `Forwarded` keeps its `proto=`, `host=`, and `by=` fields while its `for=` value is replaced with the masked IP, or with the resolved client IP when that IP is private or loopback and exempt from masking. When no client IP resolves, the `for=` pairs are removed instead. Otto re-reads the result with Rack's parser; if any other `for=` value survives, or Rack cannot parse the header (an RFC 7239 extension parameter is enough), Otto deletes the header. The first deletion in a process is logged at warn, later ones at debug. |
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
case) is accepted too, for YAML- or environment-driven configuration. The
sentinel is only valid as the whole option: a list that contains it, such as
`trusted_proxies: ['none']`, is rejected at configuration time rather than
installed as a proxy entry.

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

`Rack::Request.forwarded_priority` is a process-wide setting that selects the
main forwarding family Rack reads: `X-Forwarded-*`, RFC 7239 `Forwarded`, or
both. Otto pins it to the family selected by `trusted_proxy_header` so client-IP
resolution and Rack's main forwarded host, port, and scheme parsing agree.

This is not a complete sanitizer for requests from a trusted peer. Rack checks
some compatibility carriers independently, notably `X-Forwarded-SSL`. Otto
keeps forwarded carriers from trusted peers because it cannot distinguish
values created by the proxy from values the proxy passed through. Configure the
trusted proxy to remove client-supplied forwarding headers before setting its
own authoritative values.

The pin governs host, port, and the `X-Forwarded-Proto` / `proto=` scheme
lookup. It does not govern `X-Forwarded-SSL`: Rack (3.2.x) honors
`X-Forwarded-SSL: on` before it consults `forwarded_priority`, in every family.
Otto covers this by deleting `X-Forwarded-SSL` together with the other
authority carriers for any untrusted peer, so the header only reaches Rack from
a trusted proxy or an unconfigured deployment.

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
process that resolves proxied requests must use the same forwarding family. A
test suite that builds applications with different families must clear this
between tests: require 'otto/testing' and call Otto::Testing.reset!.
```

The two placeholders are the requested family and the already committed one.
See [Testing Otto applications](testing-guide.md#reset-ottos-process-global-state-between-tests)
for the reset.

An application that configures no proxy trust, and one that asserts
`trusted_proxies: :none`, read no forwarded chain and therefore stake no claim
on the family. Neither can block a later explicit choice, unless it also names
`trusted_proxy_header` explicitly. Otto only reads the header in depth mode,
but setting it is always a claim: it pins Rack's `forwarded_priority` and
registers the family for the process, even under `trusted_proxies: :none`.

`trusted_proxy_header` accepts `X-Forwarded-For` (the default), `Forwarded`, or
`Both`. When configuring proxy trust, `Forwarded` and `Both` require depth mode.
CIDR filter mode resolves client IPs from the `X-Forwarded-For` family only
(`X-Forwarded-For`, or `X-Real-IP` then `X-Client-IP` when it is absent or
blank; see
[How enumerated proxy trust resolves the client IP](#how-enumerated-proxy-trust-resolves-the-client-ip))
and never from RFC 7239 `Forwarded`, so a non-default family would make Rack
read a header that Otto ignores:

```text
Cannot configure trusted_proxy_header 'Forwarded' or 'Both' together with
trusted_proxies (CIDR filter mode): CIDR-walk resolves client IPs from the
X-Forwarded-For family only (X-Forwarded-For, X-Real-IP, X-Client-IP), never
RFC 7239 Forwarded. Use trusted_proxy_depth (count mode) to read the RFC 7239
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

The inner instance still enforces the application's own posture when an outer
pass has already resolved the client IP:

- `trusted_proxies: :none` always applies. The inner instance records
  `otto.via_trusted_proxy` as `false` and strips the authority carriers, whatever
  the outer instance did.
- `trusted_proxy_depth` records `true` unless a configured outer pass already
  recorded a verdict.
- `trusted_proxies: [...]` keeps the verdict of a configured outer pass. When no
  outer pass recorded one, the connecting peer can no longer be matched, because
  the outer pass rewrote `REMOTE_ADDR`. Otto then treats the peer as untrusted,
  strips the carriers, and logs a warning naming the fix: pass the application's
  security configuration to the outer instance.
