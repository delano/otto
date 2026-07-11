# Geo-country resolution

Otto resolves a country-level ISO 3166-1 alpha-2 code for each request and
exposes it as `req.geo_country` / `env['otto.privacy.geo_country']`. Resolution
is country-only by design — that is the privacy posture; there is no city or
region lookup.

## Resolution order

`Otto::Privacy::GeoResolver.resolve` returns the first hit from:

1. **Application-configured header** (`geo_header:`) — e.g. `X-Client-Country`.
2. **Known provider headers** — Cloudflare (`CF-IPCountry`), AWS CloudFront,
   Fastly, Akamai Edgescape, Azure Front Door, **Vercel**
   (`X-Vercel-IP-Country`), and a few semi-standard names
   (`X-Geo-Country`, `X-Country-Code`, `Country-Code`).
3. **Custom resolver** (`GeoResolver.custom_resolver`) — your own callable.
4. **Local MMDB database** (`geo_db_path:`) — a MaxMind-DB country database.
5. **`'**'`** — the unknown sentinel, when nothing else matches.

Steps 1 and 2 are **only consulted when geo headers can be trusted** (see
[Header trust](#header-trust-and-spoofing) below).

The database lookup in step 4 runs on the request's **masked** IP
(e.g. `203.0.113.0`) — the `ip` argument to `resolve` is the masked value, so
the database never sees the real address. Country-level MMDB networks are
almost always ≥ /24, so the default /24-masked value (`octet_precision: 1`)
resolves to the same country.

> A **`custom_resolver`** receives `(ip, env)`. Use the `ip` argument (the
> masked IP) — at geo-resolution time `env` may still carry pre-masking
> values (`REMOTE_ADDR`, forwarded headers), so a resolver that reads the
> address out of `env` can observe the real IP.

> **`octet_precision: 2`** masks two octets (a /16). That is coarser than most
> country networks, so it can reduce database hit rate for the small share of
> countries whose ranges are finer than /16 — those requests fall through to
> `'**'`. Header and custom-resolver sources are unaffected (they ignore the
> IP). Keep the default precision if you rely on the MMDB fallback.

## Configuration

All geo configuration is **boot-time only** (set once during single-threaded
initialization, before serving requests), matching `custom_resolver`'s
contract. `GeoResolver` state is process-global.

> **Multiple Otto instances in one process** share this global geo state
> (header, database, custom resolver), so the last configuration wins — the
> same last-write-wins contract as `custom_resolver`. In particular,
> `configure_ip_privacy(geo: false)` on one instance unloads the shared
> database for **all** instances (that is what "no database in memory" means).
> If different instances need different geo behavior, configure geo once,
> centrally, rather than per instance.

```ruby
otto.configure_ip_privacy(
  geo:         true,                                # default; false disables geo entirely
  geo_header:  'X-Client-Country',                 # trusted app header (optional)
  geo_db_path: 'data/geo-whois-asn-country.mmdb',  # local MMDB fallback (optional)
)
```

- **`geo: false`** short-circuits everything: no header reads, and any loaded
  database is unloaded from memory (`req.geo_country` becomes `nil`).
- **`geo_header:`** accepts either the HTTP header name (`X-Client-Country`) or
  the Rack CGI env key (`HTTP_X_CLIENT_COUNTRY`), in any case, and is
  canonicalized to the env-key form. Pass `''` to clear.
- **`geo_db_path:`** is loaded once at boot in `MODE_MEMORY`. A missing/invalid
  path (or a missing `maxmind-db` gem) raises
  `Otto::Privacy::GeoResolver::DatabaseError` **at configuration time**, not
  per-request. Pass `''` to unload.

You can also set these directly on `GeoResolver` (same boot-time contract):

```ruby
Otto::Privacy::GeoResolver.geo_header  = 'X-Client-Country'
Otto::Privacy::GeoResolver.geo_db_path = 'data/geo-whois-asn-country.mmdb'
Otto::Privacy::GeoResolver.custom_resolver = ->(ip, env) { MyService.country(ip) }
```

## The database: gem and datafile

The reader and the data file are independent — the MMDB format is the interop
point.

### Reader gem (`maxmind-db`)

The [`maxmind-db`](https://rubygems.org/gems/maxmind-db) gem (official MaxMind
reader, Apache-2.0, pure Ruby, zero runtime deps) is an **optional**
dependency. Otto only `require`s it when `geo_db_path` is set. Add it to your
app when you use the database fallback:

```ruby
# Gemfile
gem 'maxmind-db', '~> 1.4'
```

### Data file (`geo-whois-asn-country`)

The recommended data file is
[`geo-whois-asn-country`](https://github.com/sapics/ip-location-db) from
sapics/ip-location-db: **PDDL v1.0 (public domain, no attribution required)**,
rebuilt daily, shipped as MMDB. Otto vendors no database — country data goes
stale, and a public-domain file you refresh on your own schedule keeps
licensing and freshness in your control.

Download it (IPv4+IPv6) into a path of your choosing:

```bash
mkdir -p data
curl -fsSL -o data/geo-whois-asn-country.mmdb \
  https://github.com/sapics/ip-location-db/releases/download/latest/geo-whois-asn-country.mmdb
```

Otto ships `examples/update_geo_database.rb` as a small refresh helper you can
run from cron. Any MMDB country database works — GeoLite2-Country, DB-IP
Country Lite, iplocate, etc. — since `GeoResolver` tolerates the common record
schemas (`country.iso_code`, `registered_country.iso_code`, and flat
`country_code`).

> **Note on GeoLite2:** its EULA requires a MaxMind account/license key and
> obliges consumers to refresh within 30 days of each release. A PDDL dataset
> avoids both obligations.

## Header trust and spoofing

Every geo header is trivially client-spoofable unless the request actually
arrived through the CDN that sets it. Otto gates header trust on trusted-proxy
identity:

- If **trusted proxies are configured** (`config.add_trusted_proxy(...)`), geo
  headers — both the configured `geo_header` and the provider headers — are
  honored **only** for requests that arrived via a trusted proxy
  (`env['otto.via_trusted_proxy']`). A spoofed header on a direct connection is
  ignored, and resolution falls through to the custom resolver / database.
- If **no trusted proxies are configured**, there is nothing to gate against,
  so headers are trusted (legacy behavior).

This mirrors the identity-based `otto.via_trusted_proxy` contract and is
independent of count-based `trusted_proxy_depth` mode.

## Acceptance behavior summary

| Scenario | Result |
| --- | --- |
| Configured `geo_header` present and trusted | wins over provider headers |
| Non-trusted-proxy request, proxies configured | geo headers skipped |
| Database lookup | uses the masked IP only |
| `geo: false` | `nil`, no database in memory |
| Bad `geo_db_path` | raises at boot, not per-request |
| Nothing matches | `'**'` |
