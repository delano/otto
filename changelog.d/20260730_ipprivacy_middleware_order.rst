Added
-----

- ``MiddlewareStack#execution_order`` returns middleware classes in the order
  they actually run (outermost first), resolving pin tiers — unlike
  ``#middleware_list``, which reports registration order. (#219)

- ``add_with_position`` accepts ``position: :innermost`` as a clearer synonym
  for ``:first``, and a new ``position: :entrypoint`` tier that pins middleware
  outside even ``:outermost`` entries. (#219)

Security
--------

- IP masking now applies to the whole middleware stack, not just the
  application. ``IPPrivacyMiddleware`` was registered ``position: :first``,
  which is first-in-*array* and therefore **innermost**, so every other
  middleware Otto mounts — plus anything added via ``Otto#use`` — received the
  raw ``REMOTE_ADDR``, an un-anonymized User-Agent, and a nil
  ``env['otto.client_ip']``. It is now pinned outermost and runs before
  everything else. (#219)

- Rate-limit logging no longer writes raw client IPs. The ``rack.attack``
  subscribers in ``Otto::Security::RateLimiting`` and ``Otto::MCP::RateLimiter``
  interpolated ``req.ip`` into a ``warn``-level line on every blocked request,
  so deployments on the default masked profile leaked public IPs to their logs.
  Both now log a masked address. Rack::Attack is mounted outside Otto, so this
  is independent of middleware ordering. (#219)

Changed
-------

- ``Otto::LoggingHelpers.request_context`` masks its ``:ip`` field when the
  request never passed through ``IPPrivacyMiddleware`` (previously it fell back
  to the raw ``REMOTE_ADDR``). New ``LoggingHelpers.privacy_safe_ip`` exposes
  that behavior for callers outside Otto's stack. (#219)

- ``Otto::CaddyTLS::LocalhostGuard`` reads the new leak-free boolean
  ``env['otto.peer_loopback']`` — the loopback verdict ``IPPrivacyMiddleware``
  records on the untouched socket peer before masking — falling back to
  ``REMOTE_ADDR`` when absent. The guard still authenticates the raw peer,
  which it can no longer read directly now that IP masking runs first. (#219)

AI Assistance
-------------

- Middleware ordering audit, raw-peer record design, and regression coverage
  developed with AI assistance. (#219)
