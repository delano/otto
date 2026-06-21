Added
-----

- Count-based trusted-proxy resolution ("trust the last N hops"), the Express
  ``trust proxy = N`` primitive, via a new
  ``Otto::Security::Config#trusted_proxy_depth`` accessor (Integer, default
  ``nil``). ``nil`` / ``0`` keeps the existing CIDR-walk; ``>= 1`` enables depth
  mode. This is the sound model for non-enumerable proxy tiers (Fly, cloud load
  balancers, dynamic reverse proxies) whose addresses cannot be listed as CIDRs.
  Resolution flows through the shared ``Otto::Utils.resolve_client_ip``, so the
  canonical ``env['otto.client_ip']`` (masking, idempotency, "read everywhere")
  and the standalone ``Request#client_ipaddress`` fallback both honor depth with
  no further wiring. Settable through ``Otto::Security::Configurator#configure``
  (``trusted_proxy_depth:``) and the ``trusted_proxy_depth`` option of
  ``configure_security``. Depth resolves the client *IP* only; it is decoupled
  from proxy proto-trust — ``env['otto.via_trusted_proxy']`` (and therefore
  ``Otto::Request#secure?`` honoring ``X-Forwarded-Proto`` / ``X-Scheme``) remains
  the trusted-proxy *identity* check and is never derived from hop depth,
  matching the downstream OneTimeSecret behavior. (onetimesecret#3436,
  onetimesecret#3116)

Security
--------

- Depth resolution trusts exactly N hops counted from the right of
  ``X-Forwarded-For`` plus ``REMOTE_ADDR``, so a forged leftmost forwarded entry
  is never reached. Positions are counted raw (never dropped) so junk padding
  cannot shift the index, and only the selected entry is validated. A chain
  shorter than ``N + 1`` (a request that may have bypassed the proxy tier) or an
  invalid target entry falls back to ``REMOTE_ADDR`` rather than a spoofable
  forwarded value. Depth mode is XFF-only (single-value ``X-Real-IP`` /
  ``X-Client-IP`` cannot express a hop chain) and **assumes origin lockdown** —
  the app must be unreachable except through the proxy tier. CIDR-walk and depth
  are mutually exclusive, and ``trusted_proxy_depth`` must be a non-negative
  Integer or ``nil``; both are validated immediately at configuration time (with
  a freeze-time backstop), so an invalid or contradictory setup fails fast.

Documentation
-------------

- Extended ``docs/migrating/v2.3.0.md`` with a count-based depth section covering
  when to use depth vs CIDR-walk, the origin-lockdown prerequisite, configuration
  examples, Express parity, and the XFF-only / short-chain / mutual-exclusivity
  semantics.

AI Assistance
-------------

- Trusted-proxy depth design review, threat-model analysis (origin-lockdown
  trade vs CIDR enumerability, raw-position counting to defeat XFF padding),
  implementation and test coverage developed with AI pair programming.
