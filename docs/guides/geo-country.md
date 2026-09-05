# Geo-country resolution

Otto exposes a country-level ISO 3166-1 alpha-2 code as `req.geo_country` and
`env['otto.privacy.geo_country']`. It does not expose city or region data. For a
request that enters the privacy fingerprint, enabled but unresolved geo returns
`**`. The value is `nil` when IP privacy or geo resolution is disabled, or when
a private/loopback request is exempt from the fingerprint.

For the surrounding privacy profiles and environment-key contracts, see
[Privacy-preserving request data](privacy.md). ASN and anonymizer signals are
covered separately in [ASN and anonymizer enrichment](enrichment.md).

## Resolution order

For requests handled by Otto, the first valid result wins:

1. the application-configured `geo_header`;
2. built-in provider headers for Cloudflare, AWS CloudFront, Fastly, Akamai,
   Azure Front Door, Vercel, and several semi-standard country headers;
3. the process-wide `Otto::Privacy::GeoResolver.custom_resolver` callable;
4. a local MMDB reader configured with `geo_db_path` or `geo_db_reader`;
5. `**` when no source resolves a country.

Header sources are consulted only when the request arrived through a configured
CIDR trusted proxy. See [Trust geo headers](#trust-geo-headers).

The middleware gives custom resolvers a copy of the Rack environment with the
client address masked or removed. The local database lookup also masks the IP
again before calling its reader. A custom resolver called directly outside the
middleware does not receive that additional environment protection.

## Configure a trusted header or local database

All configuration is boot-time only and must be complete before the first
request:

```ruby
otto.configure_ip_privacy(
  geo: true,                              # default
  geo_header: 'X-Client-Country',         # optional trusted header
  geo_db_path: 'data/user-country.mmdb'   # optional local fallback
)
```

- `geo: false` disables all country resolution and releases the loaded reader.
- `geo_header:` accepts an HTTP header name such as `X-Client-Country` or its
  Rack key, `HTTP_X_CLIENT_COUNTRY`. A blank string clears the setting.
- `geo_db_path:` opens the database in memory during configuration. A blank
  string clears the path. An unreadable or invalid file raises `ArgumentError`;
  a missing or incompatible `maxmind-db` gem raises
  `Otto::OptionalDependencyError`.
- `geo_db_reader:` accepts an object responding to `#get(ip)`. It wins over a
  path supplied in the same call and lets applications use another MMDB reader
  or a test double.

Omitting a keyword leaves its current value unchanged. Supplying a new path
without a reader clears an earlier reader override.

`Otto::Privacy::GeoResolver.custom_resolver` is different from the options
above: it is shared by every Otto instance in the process. Set it once during
single-threaded initialization. For per-application behavior, prefer
`geo_db_reader:`.

## Install the MMDB reader

The [`maxmind-db`](https://rubygems.org/gems/maxmind-db) gem is optional. Otto
accepts versions 1.2 or newer within the 1.x series. Add it to the application:

```sh
bundle add maxmind-db --version '~> 1.2'
```

Applications that manage `Gemfile` entries manually can instead add
`gem 'maxmind-db', '~> 1.2'` and run `bundle install`.

## Download a current country database

Otto does not bundle country data. The current
[`user-country`](https://github.com/sapics/ip-location-db/tree/main/user-country/)
dataset from `sapics/ip-location-db` is an IPv4-and-IPv6 country MMDB updated
daily. Upstream recommends it for general end-user country lookup and publishes
it under PDDL 1.0. Review the upstream methodology and license for the version
you deploy.

The older `geo-whois-asn-country.mmdb` asset is no longer published. Use the
current release asset and checksum URLs:

```sh
mkdir -p data
curl -fL --retry 3 \
  -o data/user-country.mmdb \
  https://github.com/sapics/ip-location-db/releases/download/latest/user-country.mmdb
curl -fL --retry 3 \
  -o data/user-country.mmdb.sha256 \
  https://github.com/sapics/ip-location-db/releases/download/checksum/user-country.mmdb.sha256
```

Verify the download from the directory containing both files:

```sh
(cd data && shasum -a 256 -c user-country.mmdb.sha256)      # macOS/BSD
# or
(cd data && sha256sum --check user-country.mmdb.sha256)     # GNU/Linux
```

Inspect a lookup before configuring Otto:

```sh
bundle exec ruby -rmaxmind/db -e \
  "p MaxMind::DB.new('data/user-country.mmdb', mode: MaxMind::DB::MODE_MEMORY).get('8.8.8.8')"
```

The result should be a hash containing a two-letter `country_code`. Otto also
accepts GeoLite2-style nested `country.iso_code` records and a bare string in
the `country` field. Other MMDB datasets can therefore work, but their licenses,
update requirements, schemas, and accuracy remain the operator's responsibility.

Refresh the data on an operational schedule and verify the checksum before
replacing the active file. Because Otto opens the file at boot, restart the
application after replacement.

## Understand masking and accuracy

Database and custom-resolver lookups in the middleware receive a masked address.
For IPv4, the default `octet_precision: 1` keeps a `/24`; `octet_precision: 2`
keeps a `/16`. For IPv6, those settings keep `/48` and `/32`, respectively.
Masking can therefore reduce lookup accuracy when a database has more-specific
country ranges, especially for IPv6 and the coarser precision setting. Such a
miss falls through to `**`.

Header results do not depend on the masked address. Keep the default precision
and test representative IPv4 and IPv6 ranges if the MMDB fallback is important
to the application.

## Trust geo headers

Country headers are client-spoofable unless Otto can verify the connecting
proxy. Configure the CDN or reverse proxy addresses as trusted CIDRs:

```ruby
otto = Otto.new(
  'routes',
  trusted_proxies: ['10.0.0.0/8', '192.0.2.0/24']
)
```

Otto ignores configured and built-in geo headers when:

- proxy trust is not configured;
- `trusted_proxies: :none` is configured;
- the connecting peer does not match a configured trusted proxy; or
- count-based `trusted_proxy_depth` mode is used.

A configured `geo_header` and `trusted_proxy_depth` are rejected together at
configuration time. In depth-mode deployments, use `geo_db_path` or
`geo_db_reader` instead. For the broader forwarded-header boundary, see
[Forwarded host authority](forwarded-authority.md).

## Behavior summary

| Scenario | Result |
| --- | --- |
| Trusted configured header contains a valid code | Wins over provider headers |
| Geo headers are not trusted | Headers are skipped; resolver/database fallback continues |
| Local database lookup | Receives only the masked IP |
| `geo: false`, IP privacy disabled, or privacy-exempt request | `nil` |
| Enabled, but nothing resolves | `**` |
| Invalid path or database | Configuration fails at boot |
