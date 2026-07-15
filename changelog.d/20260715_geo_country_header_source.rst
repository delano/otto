Added
-----

- Configurable geo-country resolution. ``configure_ip_privacy`` now accepts
  ``geo_header:`` — a trusted, app-configured request header checked *before*
  the built-in CDN headers (e.g. ``geo_header: 'X-Client-Country'``);
  ``geo_db_path:`` — a MaxMind-format ``.mmdb`` country database giving an
  offline IP->country fallback (looked up on the masked IP; needs the optional
  ``maxmind-db`` gem); and ``geo_db_reader:`` — bring your own reader (any
  object responding to ``#get``), keeping the reader/data-source choice
  independent of Otto. A bad ``geo_db_path`` fails at boot, not per-request.
  (#206)

- ``X-Vercel-IP-Country`` is now recognized among the built-in CDN/provider
  geo headers. (#206)

Changed
-------

- Geo resolution now runs on the privacy-masked IP, so the unmasked address
  never reaches the resolver (custom resolver or database). Country-level
  networks are >= /24, so /24-masked results are identical at the default
  masking level. Custom resolvers invoked through the middleware now receive
  the masked IP. (#206)

Security
--------

- Geo headers (``CF-IPCountry`` and friends, plus any configured
  ``geo_header``) are now ignored for a request that did not arrive via a
  configured trusted proxy — every geo header is client-spoofable unless you
  are actually behind that CDN. When no trusted proxies are configured,
  behavior is unchanged. (#206)

AI Assistance
-------------

- Configurable geo-header source and local IP->country database fallback
  designed and implemented with AI assistance, including test coverage for
  header precedence, spoofing, IPv6, ``geo: false``, and boot-time validation.
  (#206)
