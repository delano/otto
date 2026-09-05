Added
-----

- Directly exposed applications can now set ``trusted_proxies: :none`` or call
  ``trust_no_proxies!`` to distrust every peer. Otto then ignores forwarded
  client IPs and strips forwarded host, scheme, and port metadata. Leaving proxy
  trust unconfigured continues to preserve forwarded metadata. Applications
  behind a reverse proxy, including one on loopback, must explicitly trust it.
  The sentinel is only valid as the whole option; a list containing it, such
  as ``['none']``, is rejected at configuration time. See
  ``docs/guides/forwarded-authority.md`` for configuration guidance. (#259)

Security
--------

- ``IPPrivacyMiddleware`` enforces its own proxy trust posture even when an
  outer instance already resolved ``otto.client_ip``. ``trusted_proxies: :none``
  always strips forwarded authority; a CIDR configuration that can no longer
  match the connecting peer treats it as untrusted and logs a warning. (#259)

- ``env['otto.peer_relayed']`` records whether a request carried any relay
  marker header, evaluated before forwarded carriers may be deleted, so
  ``Otto::CaddyTLS::LocalhostGuard`` still refuses a relayed loopback call once
  the carriers are stripped. The relay markers cover every carrier the scrub
  deletes, including ``X-Forwarded-Host`` and the other authority headers, not
  only the client-IP carriers. (#259)
