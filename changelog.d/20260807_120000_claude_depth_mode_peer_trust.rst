Fixed
-----

- Depth mode now records a peer-trust verdict in
  ``env['otto.via_trusted_proxy']``. Configuring ``trusted_proxy_depth >= 1``
  forces an empty trusted-proxy matcher list (the modes are mutually
  exclusive), which short-circuited the identity check to ``false`` on every
  request — while ``REMOTE_ADDR`` was still rewritten to the resolved client
  IP, leaving downstream middleware (e.g. forwarded-host handling) with no
  trust signal at all. Configuring a depth is the operator's assertion that
  the connecting peer is their proxy tier, so the peer is now trusted
  whenever depth mode is active; ``Otto::Request#forwarded_by_trusted_proxy?``
  (and therefore ``#secure?``'s X-Forwarded-Proto authorization) mirrors the
  same grant on its no-middleware fallback path. Geo-header trust is
  unchanged: it stays gated on enumerated CIDR matchers, since a hop trusted
  by count cannot be verified as a geo-setting CDN. (#226)
