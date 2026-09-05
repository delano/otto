# Configure IP privacy

This page is a short entry point for existing links and searches. The canonical
[privacy guide](privacy.md) documents Otto's current profiles, request helpers,
environment keys, proxy trust boundary, and middleware placement.

## Choose a profile

Configure privacy before the first request:

```ruby
otto = Otto.new('routes')
otto.configure_ip_privacy(profile: :masked)     # default: mask public IPs
otto.configure_ip_privacy(profile: :anonymous)  # also mask private and loopback IPs
```

Use `profile: :audit` only when the application must retain resolved client IPs
and the deployment has its own access, logging, and retention controls. See
[Profiles](privacy.md#profiles) for the exact behavior of each profile.

These profiles are technical data-minimization controls. They do not determine
whether an application complies with GDPR, CCPA, or another legal regime.
Compliance also depends on the application's purposes, notices, retention,
access controls, vendors, and jurisdiction.

## Complete common tasks

- Read the current request helpers and Rack environment keys in
  [Privacy-safe request values](privacy.md#privacy-safe-request-values).
- Put privacy ahead of logging and monitoring middleware outside Otto's own
  stack by following [Middleware placement](privacy.md#middleware-placement).
- Configure forwarded client-IP trust in
  [Trusted proxy and matching boundaries](privacy.md#trusted-proxy-and-matching-boundaries).
- Configure country lookup in [Geo-country resolution](geo-country.md).
- Configure opt-in ASN or anonymizer lookup in
  [ASN and anonymizer enrichment](enrichment.md).

Do not copy configuration or environment-key examples from older versions of
this page; use the linked canonical sections instead.
