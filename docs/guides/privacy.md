# Privacy-preserving request data

Otto's default request posture is to reduce the precision of public client
information before application code, logging, authentication, rate limiting,
and other middleware see it. The privacy pipeline is a Rack concern, not only a
router feature: if an outer Rack middleware logs the request before Otto runs,
place the privacy middleware in the common stack first.

## Default behavior

With the default `:masked` profile:

- public IP addresses are masked by the configured octet precision (one octet
  by default: `203.0.113.9` becomes `203.0.113.0`);
- private and localhost addresses remain unmasked for development by default;
- public user agents have version details anonymized;
- public referers have query parameters removed;
- the original public values are not retained in the Rack environment;
- country resolution is country-level only and returns an unknown sentinel when
  no configured source answers.

Downstream code should read `req.ip`, `req.masked_ip`, and the privacy environment
keys rather than recovering a raw address from forwarded headers.

## Profiles

Choose a named profile when the deployment posture should be obvious in review:

```ruby
otto = Otto.new('routes')
otto.configure_ip_privacy(profile: :masked)     # default
# or:
otto.configure_ip_privacy(profile: :anonymous)  # mask private/localhost too
# or:
otto.configure_ip_privacy(profile: :audit)      # disable IP privacy
```

| Profile | Public IPs | Private/localhost IPs | Use when |
| --- | --- | --- | --- |
| `:masked` | Masked | Exempt by default | General privacy-by-default deployments and local development. |
| `:anonymous` | Masked | Masked | Internal addresses must also be treated as identifying data. |
| `:audit` | Not masked | Not masked | The operator has deliberately accepted raw-IP retention and controls logs and downstream systems. |

The `:audit` profile transfers retention responsibility to the operator. It is
not a way to obtain precise matching while keeping privacy enabled; use
`env['otto.ip_match']` for that narrower need.

Configuration is boot-time only. The first request freezes configuration in
normal operation, so set profiles, trusted proxies, database readers, and other
privacy settings before serving traffic.

## Privacy-safe request values

Inside a handler:

```ruby
class Analytics
  def self.record(req, res)
    event = {
      ip: req.ip,
      country: req.geo_country,
      asn: req.asn,
      anonymizer: req.anonymizer,
      user_agent: req.user_agent,
    }

    AuditLog.write(event)
    res.status = 204
    res.body = []
  end
end
```

Common values are also available in the Rack environment:

| Value | Environment key | Contract |
| --- | --- | --- |
| Canonical client IP | `otto.client_ip` | Privacy-applied client IP used downstream. |
| Masked IP | `otto.privacy.masked_ip` | Present for a public address when masking applies. |
| Rotating IP hash | `otto.privacy.hashed_ip` | Privacy-safe correlation value using Otto's rotating key. |
| Stable correlation hash | `otto.privacy.correlation_hash` | Present only when `correlation_secret:` is configured and the privacy pipeline produces it. |
| Country | `otto.privacy.geo_country` | ISO 3166-1 alpha-2 code or `'**'`; `nil` when privacy is disabled. |
| ASN | `otto.privacy.asn` | `nil` when off, `'**'` when enabled but unresolved, or a value such as `'AS15169'`. |
| Anonymizer | `otto.privacy.anonymizer` | `nil` when off, `'**'` when no database answers, or a classification label. |

`req.hashed_ip` is designed for short-lived correlation using a rotating key.
For long-lived correlation, explicitly configure a stable secret and protect
that secret as sensitive configuration. Changing the secret changes every
correlation hash.

## Country, ASN, and anonymizer data

These signals have different trust and precision models:

- [Geo-country resolution](../geo-country.md) documents trusted provider
  headers, CIDR trusted-proxy requirements, masked MMDB lookup, and the unknown
  sentinel.
- [ASN and anonymizer enrichment](../enrichment.md) documents the opt-in
  database contracts. ASN uses a masked address; anonymizer classification
  deliberately uses the unmasked address internally and emits only a label.

Enable optional signals explicitly:

```ruby
otto.configure_ip_privacy(
  geo: true,
  geo_db_path: 'data/country.mmdb',
  asn: true,
  asn_db_path: 'data/origin-asn.mmdb',
  anonymizer: true,
  anonymizer_db_path: 'data/anonymizer.mmdb'
)
```

The `maxmind-db` gem is optional and is required only when a database path is
configured. A reader object responding to `#get(ip)` can be injected instead.
Database paths are opened at configuration time; invalid paths fail during boot
rather than on an arbitrary request.

## Trusted proxy and matching boundaries

Configure trusted proxies before relying on forwarded client information:

```ruby
otto = Otto.new(
  'routes',
  trusted_proxies: ['10.0.0.0/8', '192.0.2.0/24']
)
```

CIDR-based trust lets Otto verify the proxy peer. Count-based
`trusted_proxy_depth` is a separate mode and does not make geo headers
trustworthy. A configured `geo_header` combined with depth mode is rejected at
configuration time; use a local database in depth-mode deployments instead.

The same trust decision also gates the forwarded host, scheme, and port headers
that `Rack::Request#host` reads. See
[Forwarded host authority](forwarded-authority.md), including the explicit
`trusted_proxies: :none` assertion for directly exposed applications.

For precise access control without exposing the address to application code,
configure or call the verdict-only `env['otto.ip_match']` capability. It matches
the resolved full client IP against application CIDRs and returns only
`true`/`false`; it fails closed when no client IP resolves. Do not log or persist
the closure's captured address.

## Middleware placement

When building a larger Rack stack, put privacy before components that log or
inspect the request:

```ruby
builder.use Otto::Security::Middleware::IPPrivacyMiddleware, otto.security_config
builder.use Rack::CommonLogger
builder.use Sentry::Rack::CaptureExceptions
# Then mount the Otto application.
```

Otto also installs its privacy middleware internally. The outer common-stack
placement is needed when middleware outside the Otto app would otherwise see the
raw peer first.

Pass `otto.security_config` as shown. The outer instance resolves `otto.client_ip`
first and the inner one then short-circuits, so an outer instance constructed
without the configuration would silently apply defaults instead of the
application's profile, precision, correlation secret, and enrichment settings.
Proxy trust is the exception: the inner instance re-applies its own trust
posture even after an outer pass, and a CIDR configuration that can no longer
see the connecting peer fails closed. See
[Forwarded host authority](forwarded-authority.md#place-the-middleware-before-other-request-consumers).

## Operational rules

- Treat `nil`, `'**'`, `'none'`, and a real label as different states. In
  particular, anonymizer `'none'` means the database was consulted and did not
  list the address; `'**'` means no database answered.
- Do not use provider geo headers without a verifiable CIDR trusted proxy. A
  client can otherwise submit its own country.
- Do not confuse the masked client IP with the raw peer used to authenticate a
  local network service. Integrations such as Caddy TLS have their own trust
  boundary.
- Test logs and monitoring outside Otto's stack. Privacy is only effective if
  those components receive the masked environment first.
