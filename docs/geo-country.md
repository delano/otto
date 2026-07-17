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
   Unlike the other geo settings, this is **class-level** (see
   [Configuration](#configuration)).
4. **Local MMDB database** (`geo_db_path:` / `geo_db_reader:`) — a MaxMind-DB
   country database.
5. **`'**'`** — the unknown sentinel, when nothing else matches.

Steps 1 and 2 are **only consulted when geo headers can be trusted** (see
[Header trust](#header-trust-and-spoofing) below).

Resolution is **honest**: Otto does not guess from a hardcoded IP-range table.
When no header, custom resolver, or database resolves a country, the result is
`'**'`.

### Privacy: masked IP and masked env

The database lookup in step 4 runs on the request's **masked** IP
(e.g. `203.0.113.0`), never the real address. `check_geo_database` masks the IP
internally with the config's `octet_precision` before the lookup, so even a
direct `GeoResolver.resolve` caller passing a real IP does not expose it to the
database. Country-level MMDB networks are almost always ≥ /24, so the default
/24-masked value (`octet_precision: 1`) resolves to the same country.

In the middleware path Otto additionally hands `resolve` a **masked env view**:
`REMOTE_ADDR`, `X-Forwarded-For`, `X-Real-IP`, `X-Client-IP`, and the RFC 7239
`Forwarded` header are masked. So a `custom_resolver` cannot read the raw client
IP out of `env` either — use the `ip` argument (already masked), not `env`.

> **`octet_precision: 2`** masks two octets (a /16). That is coarser than most
> country networks, so it can reduce database hit rate for the small share of
> countries whose ranges are finer than /16 — those requests fall through to
> `'**'`. Header and custom-resolver sources are unaffected (they ignore the
> IP). Keep the default precision if you rely on the MMDB fallback.

## Configuration

All geo configuration is **boot-time only** (set once during single-threaded
initialization, before serving requests), matching `custom_resolver`'s
contract. `geo_header`, `geo_db_path`, and `geo_db_reader` are stored on the
instance's `Otto::Privacy::Config`, so separate Otto instances hold independent
geo configuration.

> **`custom_resolver` is the exception — it is class-level, not per-instance.**
> `GeoResolver.custom_resolver=` sets a singleton on the `GeoResolver` class, so
> it is **shared across every Otto instance in the process** (last write wins).
> If you run multiple Otto instances that need different resolver strategies,
> the custom resolver cannot distinguish them — branch inside a single resolver
> on `env`, or use per-instance `geo_db_reader` instead.

```ruby
otto.configure_ip_privacy(
  geo:           true,                                # default; false disables geo entirely
  geo_header:    'X-Client-Country',                 # trusted app header (optional)
  geo_db_path:   'data/geo-whois-asn-country.mmdb',  # local MMDB fallback (optional)
  # geo_db_reader: MaxMind::DB.new(path),            # or bring your own reader (optional)
)
```

- **`geo: false`** short-circuits everything: no header reads, and any loaded
  database is unloaded from memory (`req.geo_country` becomes `nil`).
- **`geo_header:`** accepts either the HTTP header name (`X-Client-Country`) or
  the Rack CGI env key (`HTTP_X_CLIENT_COUNTRY`), in any case, and is
  canonicalized to the env-key form. Pass `''` to clear.
- **`geo_db_path:`** is loaded once at boot in `MODE_MEMORY`. An unreadable
  path, a corrupt/non-MMDB file, or a missing `maxmind-db` gem raises
  `ArgumentError` **at configuration time**, not per-request. Pass `''` to
  unload.
- **`geo_db_reader:`** injects any object responding to `#get(ip)` (a
  preconfigured `MaxMind::DB` reader or a test double), keeping the reader and
  data-source choice independent of Otto. It **overrides** `geo_db_path` when
  both are given in the same call; supplying `geo_db_path` alone in a later call
  clears a prior reader override.

Each keyword follows a `nil` = "leave unchanged" contract; pass `''` to a header
or path to clear it. Any geo-affecting change triggers the boot-time database
(re)load, so a bad `geo_db_path` fails at the `configure_ip_privacy` call.

## The database: gem and datafile

The reader and the data file are independent — the MMDB format is the interop
point.

### Reader gem (`maxmind-db`)

The [`maxmind-db`](https://rubygems.org/gems/maxmind-db) gem (official MaxMind
reader, Apache-2.0, pure Ruby, zero runtime deps) is an **optional**
dependency. Otto only `require`s it when a database is configured. Add it to
your app when you use the database fallback:

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

Refresh it on your own schedule (e.g. a daily cron job running the same curl).
Any MMDB country database works — GeoLite2-Country, DB-IP Country Lite,
iplocate, etc. — since `GeoResolver` tolerates the record shapes country
databases actually use: nested `country.iso_code` (GeoLite2-Country style), a
flat `country_code` string, and a bare-string `country`.

> **Note on GeoLite2:** its EULA requires a MaxMind account/license key and
> obliges consumers to refresh within 30 days of each release. A PDDL dataset
> avoids both obligations.

## Header trust and spoofing

Every geo header is trivially client-spoofable unless the request actually
arrived through the CDN that sets it. Otto trusts geo headers — both the
configured `geo_header` and the provider headers — **only** for a request that
demonstrably arrived via a configured **CIDR trusted proxy**
(`env['otto.via_trusted_proxy']` with `trusted_proxies` configured). A spoofed
header on a direct connection is ignored, and resolution falls through to the
custom resolver / database.

Origins Otto cannot verify are **not** trusted:

- **No trusted-proxy configuration.** A direct internet client could otherwise
  pick its own country by sending `CF-IPCountry` / `X-Client-Country`, so with
  no `trusted_proxies` configured, header steps are skipped and resolution falls
  to the resolver / database (`'**'` if neither is set).
- **Count-based `trusted_proxy_depth` mode.** The header-setting hop cannot be
  verified as a geo-CDN, so depth mode does not enable header trust.

**Migration:** to keep header-based geo, configure `trusted_proxies` (CIDR
matchers) so Otto can verify the proxy origin. Depth-mode and header-only
deployments should set `geo_db_path` for a local database instead; otherwise
resolution returns `'**'`.

## Acceptance behavior summary

| Scenario | Result |
| --- | --- |
| Configured `geo_header` present and trusted | wins over provider headers |
| Request not via a verified CIDR trusted proxy | geo headers skipped |
| No `trusted_proxies` configured | geo headers skipped (not trusted) |
| Database lookup | uses the masked IP only |
| `geo: false` | `nil`, no database in memory |
| Bad `geo_db_path` | raises at boot, not per-request |
| Nothing matches | `'**'` |
