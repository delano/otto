Added
-----

- Geo-country resolution is now configurable and backed by a real IP→country
  database. ``configure_ip_privacy`` accepts ``geo_header:`` (an
  application-trusted header such as ``X-Client-Country`` that outranks the
  built-in CDN headers) and ``geo_db_path:`` (a MaxMind-DB ``.mmdb`` country
  database used as a local fallback, loaded once at boot in ``MODE_MEMORY``).
  ``X-Vercel-IP-Country`` joins the recognized provider headers. The
  ``maxmind-db`` gem is an optional dependency, required only when
  ``geo_db_path`` is set. (delano/otto#206)

Changed
-------

- ``Otto::Privacy::GeoResolver.resolve`` now follows a first-hit-wins order:
  configured header → provider headers → ``custom_resolver`` → local MMDB
  lookup → ``'**'``. The resolver's IP argument is the **masked** IP, so the
  database lookup never sees the real address (country-level networks are
  ≥ /24, so the /24-masked value resolves to the same country). A
  ``custom_resolver`` should use that ``ip`` argument rather than reading the
  raw address from ``env``. (delano/otto#206)

Removed
-------

- The toy built-in ``KNOWN_RANGES`` IP-range table (~14 hardcoded CIDRs) is
  gone; configure ``geo_db_path`` for a real database fallback instead. With
  no header, ``custom_resolver``, or database configured, ``geo_country`` is
  now ``'**'`` rather than a guess from that table. (delano/otto#206)

Security
--------

- Geo headers are now gated on trusted-proxy identity: when trusted proxies
  are configured, ``GeoResolver`` only honors geo headers (configured or
  provider) for requests that actually arrived via a trusted proxy
  (``otto.via_trusted_proxy``). Every geo header is client-spoofable when you
  are not behind the CDN that sets it. (delano/otto#206)
