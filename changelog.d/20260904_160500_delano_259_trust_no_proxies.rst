Added
-----

- Applications exposed directly can now set ``trusted_proxies: :none`` or call
  ``trust_no_proxies!`` to distrust every peer and strip forwarded authority
  metadata. This differs from leaving proxy trust unconfigured, which preserves
  forwarded metadata. Applications behind a reverse proxy, including one on
  loopback, must explicitly trust that proxy instead. See
  ``docs/guides/forwarded-authority.md`` for configuration guidance. (#259)

- ``env['otto.peer_relayed']`` records whether a request carried any relay
  marker header, evaluated before forwarded carriers may be deleted, so
  ``Otto::CaddyTLS::LocalhostGuard`` still refuses a relayed loopback call once
  the carriers are stripped. (#259)
