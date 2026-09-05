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

For requests that pass through the privacy fingerprint pipeline, each signal
uses these values:

| Value | Meaning |
| --- | --- |
| `nil` | no enrichment value was produced: the signal is off, IP privacy is disabled, no client IP resolved, or the client is exempt from fingerprinting |
| `'**'` | the signal is on, but no database answered or the lookup failed |
| a label | the configured reader returned a usable answer |

By default, private and localhost clients are exempt from fingerprinting. Their
enrichment environment keys are absent even when the signals are enabled. Use
the `:anonymous` privacy profile only if those clients should also be masked and
enriched.

## Configuration

Add the optional reader gem when configuring an MMDB path:

```ruby
# Gemfile
gem 'maxmind-db', '~> 1.2'
```

Then install an ASN database and enable the signal before the first request:

```sh
bundle install
mkdir -p data
curl -fsSL -o data/origin-asn.mmdb \
  https://github.com/sapics/ip-location-db/releases/download/latest/origin-asn.mmdb
```

```ruby
otto.configure_ip_privacy(
  asn: true,
  asn_db_path: 'data/origin-asn.mmdb'
)
```

Anonymizer classification requires a separate compatible database that Otto
does not provide:

```ruby
otto.configure_ip_privacy(
  anonymizer: true,
  anonymizer_db_path: 'data/your-anonymous-ip.mmdb'
)
```

Do not use that placeholder path until the file exists. Both signals also accept
a bring-your-own reader (`asn_db_reader:` / `anonymizer_db_reader:`): any object
responding to `#get(ip)`. A reader supplied in the same call wins over a path.

The `maxmind-db` gem is loaded only when an enabled signal has a `*_db_path`.
Otto supports version 1.2.0 or newer in the 1.x series. Missing or incompatible
versions raise `Otto::OptionalDependencyError` during configuration. An
unreadable path also raises during configuration when its signal is enabled; a
path attached to a disabled signal is stored but not opened.

## ASN: which address is looked up, and why that's safe

The ASN lookup always uses the **masked** IP, same as geo. With the default
IPv4 `/24` masking, accuracy depends on the chosen database assigning the same
ASN across that `/24`; Otto accepts arbitrary MMDBs and injected readers, so it
cannot guarantee that equivalence. IPv6 is coarser: at `octet_precision: 1`
Otto zeroes the last 80 bits to produce a `/48`, which is wider than many IPv6
announcements. Treat masked ASN results as best-effort and verify the behavior
of the data source used by policy code.

### Data file

> **Dataset distinction:** sapics/ip-location-db publishes country and ASN data
> as separate file types. Current country files such as `user-country.mmdb` do
> not contain ASN records. Use an ASN file such as `origin-asn.mmdb` for this
> signal.

The recommended ASN file is
[`origin-asn`](https://github.com/sapics/ip-location-db/tree/main/origin-asn/)
from sapics/ip-location-db. It is **PDDL v1.0 (public domain)**, rebuilt daily,
and downloaded by the setup command above.

Compatible records must provide an integer `autonomous_system_number` either at
the top level or inside an `asn` map; Otto also accepts a bare integer `asn`
field. Reserved ASNs (0 per RFC 7607 and the AS_TRANS placeholder 23456 per RFC
6793) resolve to `'**'` rather than being reported as operators.

## Anonymizer: the one unmasked lookup

Anonymizer classification reads the **unmasked** address. This is deliberate
and documented in `AnonymizerResolver` itself: anonymizer databases list
individual egress nodes at or near /32, so the /24 equivalence that justifies
masked geo and ASN lookups does not hold. A masked lookup would flag a whole
/24 because one host in it runs a Tor exit, and miss the exit node itself —
wrong in both directions.

Otto passes the full address to the configured
`anonymizer_db_reader#get(ip)` and retains only the returned label. Because the
reader may be any application-provided object, Otto cannot guarantee that the
reader does not log, persist, or transmit the address. Use a trusted local
reader and review its network, logging, and retention behavior. Otto itself does
not place the raw address in the enrichment result or downstream environment.

### Reading the labels

When several database flags are set at once (a Tor exit hosted at a cloud
provider), the **most specific** label wins: `tor` > `proxy` > `vpn` >
`residential_proxy` > `hosting` > `anonymous`.

Two labels deserve care:

- **`'none'`** means the reader was consulted and returned no record or no
  recognized true flag. For an anonymous-IP MMDB, this normally means the
  address is not listed, but it is *not* a positive assertion that the visitor
  is residential. The result is only as reliable and current as the reader's
  data.
- **`'**'`** means no database answered at all. Do not collapse it into
  `'none'`: `'none'` is evidence, `'**'` is the absence of evidence. A
  "block anonymizers" rule that treats `'**'` as `'none'` fails open when
  the database file goes missing.

### Data file

This signal is bring-your-own-database. `AnonymizerResolver` expects top-level
fields matching the MaxMind GeoIP2 Anonymous-IP schema:
`is_tor_exit_node`, `is_public_proxy`, `is_anonymous_vpn`,
`is_residential_proxy`, `is_hosting_provider`, and `is_anonymous`. Verify the
record shape before choosing a commercial or self-built MMDB.

The [Tor bulk exit list](https://check.torproject.org/torbulkexitlist) can be an
input to a self-built database, but Otto does not include an MMDB compiler or an
update job. A generated record must set `is_tor_exit_node` at the top level, and
the deployment must refresh and verify the file on its own schedule.

## Acceptance behavior summary

| Scenario | Result |
| --- | --- |
| Signal not enabled | `nil` when read; a processed public request may carry an env key whose value is `nil` |
| IP privacy disabled or no client IP resolves | `nil`; no enrichment values are written |
| Enabled, no database configured | `'**'` for a non-exempt request |
| Database read raises | `'**'` (a lookup must never crash a request) |
| ASN lookup | masked IP only (re-masked defensively in the resolver) |
| Anonymizer lookup | the configured reader receives the unmasked IP; Otto exposes only its label |
| Private/localhost client under the default profile | no enrichment keys in env |
| Bad `*_db_path` for an enabled signal | raises during configuration, not per-request |
