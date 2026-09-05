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

- Proxy trust is now enforced when privacy middleware runs in both a shared Rack
  stack and an Otto application. The application applies its own trust posture
  before retaining forwarded authority metadata. (#259)

- Caddy on-demand TLS authorization now rejects relayed loopback requests even
  when untrusted forwarded authority metadata is stripped first. (#259)
