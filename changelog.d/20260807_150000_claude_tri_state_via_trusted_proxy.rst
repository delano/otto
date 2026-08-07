Changed
-------

- ``env['otto.via_trusted_proxy']`` is now TRI-STATE: IPPrivacyMiddleware
  writes it only when proxy trust is actually configured
  (``Security::Config#proxy_trust_configured?`` — CIDR matchers or a
  ``trusted_proxy_depth``). Previously the key was written ``false`` on every
  request of an unconfigured deployment, making ``false`` ambiguous between
  "trust is configured and this peer failed it" and "no proxy trust
  configured at all" — which forced downstream consumers (e.g.
  OneTimeSecret's forwarded-host middleware) into grant-only reads that could
  never treat a ``false`` as an authoritative deny. Now a PRESENT key is
  authoritative in both directions, and an ABSENT key means "unconfigured":
  the one case where a consumer may safely apply its own legacy heuristics.
  ``Otto::Request#forwarded_by_trusted_proxy?`` already evaluates the config
  directly when the key is absent, so in-process behavior is unchanged;
  consumers reading the raw env key should switch from ``== true`` grants to
  presence-checked reads (``env.key?`` then trust the boolean).
