Changed
-------

- Configuring an ip-privacy ``geo_header`` together with
  ``trusted_proxy_depth`` now raises ``ArgumentError`` at configuration time
  (both assignment orders, plus a freeze-time backstop for direct
  ``ip_privacy_config.geo_header=`` writes). Geo headers are only honored for
  peers matching enumerated ``trusted_proxies`` CIDR matchers — a hop trusted
  by count cannot be verified as the geo-setting CDN — so under depth mode a
  configured ``geo_header`` could never be consulted and silently fell back
  to the database/``'**'`` on every request. The built-in provider headers
  and database-backed geo (``geo_db_path`` / ``geo_db_reader``) remain fully
  supported under depth.

Documentation
-------------

- Corrected the v2.3.0 migration guide's OneTimeSecret depth-porting
  guidance: map ``trusted_proxy_depth = ots_depth`` directly, **not**
  ``ots_depth + 1``. Otto's ``chain[-(N+1)]`` index already accounts for the
  appended ``REMOTE_ADDR``, so depth N means "N proxy hops counting the
  connecting peer" — the operator-facing meaning of OTS ``depth: N``. The
  previous ``+1`` recommendation reproduced an internal off-by-one of the
  deleted OTS walker: it made honest documented-topology requests resolve
  the proxy address (short-chain fallback) and let a single forged leftmost
  ``X-Forwarded-For`` entry be selected as the client.
