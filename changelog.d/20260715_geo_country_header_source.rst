Added
-----

- Configurable geo-country resolution. ``configure_ip_privacy`` now accepts
  ``geo_header:`` — a trusted, app-configured request header checked *before*
  the built-in CDN headers (e.g. ``geo_header: 'X-Client-Country'``);
  ``geo_db_path:`` — a MaxMind-format ``.mmdb`` country database giving an
  offline IP->country fallback (needs the optional ``maxmind-db`` gem); and
  ``geo_db_reader:`` — bring your own reader (any object responding to
  ``#get``), keeping the reader/data-source choice independent of Otto. A bad
  ``geo_db_path`` fails at boot, not per-request. (#206)

- ``X-Vercel-IP-Country`` is now recognized among the built-in CDN/provider
  geo headers. (#206)

Changed
-------

- Geo resolution now runs against a privacy-masked view — the masked IP and an
  env with the IP-bearing headers masked — so the unmasked address never
  reaches a custom resolver or the database, by argument or via env. Country
  networks are >= /24, so /24-masked results are identical at the default
  masking level. A custom resolver invoked through the middleware now receives
  the masked IP (and masked env); direct ``GeoResolver.resolve`` callers are
  unchanged. (#206)

- A configured geo database is authoritative: a lookup miss (or an unusable
  result) resolves to ``'**'`` rather than falling back to the built-in
  best-effort IP-range table, which is only consulted when no database is
  configured. (#206)

Security
--------

- Geo headers (``CF-IPCountry`` and friends, plus any configured
  ``geo_header``) are ignored unless Otto can trust their origin: honored only
  for a request that arrived via a configured trusted proxy (CIDR mode); never
  trusted in count-based depth mode, where the header-setting hop can't be
  verified as a geo-CDN (resolution falls to the local database). When no
  trusted proxies are configured, behavior is unchanged. Every geo header is
  client-spoofable unless you are actually behind that CDN. (#206)

AI Assistance
-------------

- Configurable geo-header source and local IP->country database fallback
  designed and implemented with AI assistance, including adversarial review and
  test coverage for header precedence, spoofing, depth-mode trust, IPv6,
  ``geo: false``, custom-resolver sealing, boot-time validation, and the real
  ``maxmind-db`` reader against a generated fixture. (#206)
