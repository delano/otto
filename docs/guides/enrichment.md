# ASN and anonymizer enrichment

Two opt-in, country-adjacent signals layered on the same privacy pipeline as
[geo-country](geo-country.md):

- **ASN** — the network operator an address belongs to, as `req.asn` /
  `env['otto.privacy.asn']`: `'AS15169'`.
- **Anonymizer** — whether the address is a known anonymizing egress, as
  `req.anonymizer` / `env['otto.privacy.anonymizer']`: `'tor'`, `'proxy'`,
  `'vpn'`, `'residential_proxy'`, `'hosting'`, `'anonymous'`, `'none'`, `'**'`.

Both are **off by default** (unlike geo) and **database-only**: no CDN
publishes a client-ASN or anonymizer header with meaningful deployment, so
there is no header tier and none of geo's header-trust machinery applies —
including the `geo_header`/`trusted_proxy_depth` boot conflict.

Every signal keeps the same three-state contract:

| Value | Meaning |
| --- | --- |
| `nil` | the signal is switched off |
| `'**'` | switched on, but nothing resolved (no database, or lookup failed) |
| a label | a real answer |

## Configuration

```ruby
otto.configure_ip_privacy(
  asn: true,
  asn_db_path: 'data/origin-asn.mmdb',
  anonymizer: true,
  anonymizer_db_path: 'data/anonymizer.mmdb',
)
```

Both accept the same bring-your-own-reader seam as geo (`asn_db_reader:` /
`anonymizer_db_reader:` — any object responding to `#get(ip)`; a reader
supplied in the same call wins over a path). Bad paths raise at boot, not
per-request. The [`maxmind-db`](https://rubygems.org/gems/maxmind-db) gem is
required only when a `*_db_path` is configured.

## ASN: which address is looked up, and why that's safe

The ASN lookup uses the **masked** IP, same as geo. This is not a compromise:
IPv4 BGP routes are not announced longer than /24, so a /24-masked address
falls inside the same announced prefix — and therefore the same ASN — as the
real one. (IPv6 is coarser: at `octet_precision: 1` Otto zeroes the last 80
bits, wider than many IPv6 announcements, so treat IPv6 ASN as best-effort.)

### Data file

> **Naming caution:** the country database this project recommends,
> `geo-whois-asn-country`, does **not** contain ASN data. In
> sapics/ip-location-db naming, `geo-whois-asn` describes the *sources* the
> country data was derived from; the final token (`-country`) is what the
> records contain. ASN data is a separate file type in that project.

The recommended ASN file is
[`origin-asn`](https://github.com/sapics/ip-location-db/tree/main/origin-asn/)
from sapics/ip-location-db — like `geo-whois-asn-country` it is **PDDL v1.0
(public domain)** and rebuilt daily, so the licensing/freshness posture
matches the geo guidance:

```bash
curl -fsSL -o data/origin-asn.mmdb \
  https://github.com/sapics/ip-location-db/releases/download/latest/origin-asn.mmdb
```

Its records carry a flat `autonomous_system_number` (verified against the
published file), which is the primary key `AsnResolver` reads. GeoLite2-ASN
and DB-IP ASN Lite MMDBs work too (same key; GeoLite2's EULA caveats from the
geo doc apply). Reserved ASNs (0 per RFC 7607, the AS_TRANS placeholder 23456
per RFC 6793) resolve to `'**'` rather than being reported as operators.

## Anonymizer: the one unmasked lookup

Anonymizer classification reads the **unmasked** address. This is deliberate
and documented in `AnonymizerResolver` itself: anonymizer databases list
individual egress nodes at or near /32, so the /24 equivalence that justifies
masked geo and ASN lookups does not hold. A masked lookup would flag a whole
/24 because one host in it runs a Tor exit, and miss the exit node itself —
wrong in both directions.

The privacy containment is the same one Otto already relies on for
`hash_ip` and `env['otto.ip_match']`, which also consume the full IP: **only
the derived value leaves**. The resolver returns a label; the address is
never persisted, serialized, or handed downstream.

### Reading the labels

When several database flags are set at once (a Tor exit hosted at a cloud
provider), the **most specific** label wins: `tor` > `proxy` > `vpn` >
`residential_proxy` > `hosting` > `anonymous`.

Two labels deserve care:

- **`'none'`** means the database was consulted and does not list the
  address. For an anonymizer database that is a real answer (these files
  record only flagged addresses), but it is *not* a positive assertion the
  visitor is residential — it is only as fresh as your database file.
- **`'**'`** means no database answered at all. Do not collapse it into
  `'none'`: `'none'` is evidence, `'**'` is the absence of evidence. A
  "block anonymizers" rule that treats `'**'` as `'none'` fails open when
  the database file goes missing.

### Data file

There is no public-domain anonymizer dataset of `origin-asn`'s quality; this
signal is bring-your-own-database. `AnonymizerResolver` reads the MaxMind
GeoIP2 Anonymous-IP flag schema (`is_tor_exit_node`, `is_public_proxy`,
`is_anonymous_vpn`, `is_residential_proxy`, `is_hosting_provider`,
`is_anonymous`), which commercial and self-built MMDBs alike use. A workable
self-built option: compile the [Tor bulk exit
list](https://check.torproject.org/torbulkexitlist) into an MMDB with
`is_tor_exit_node` set — that covers the highest-signal label with fully
public data.

## Acceptance behavior summary

| Scenario | Result |
| --- | --- |
| Signal not enabled | `nil` everywhere (env key absent for exempt IPs) |
| Enabled, no database configured | `'**'` |
| Database read raises | `'**'` (a lookup must never crash a request) |
| ASN lookup | masked IP only (re-masked defensively in the resolver) |
| Anonymizer lookup | unmasked IP in, label out, nothing else retained |
| Private/localhost client (privacy-exempt) | no enrichment keys in env |
| Bad `*_db_path` | raises at boot, not per-request |
