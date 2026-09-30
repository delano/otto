Security
--------

- With ``trusted_proxies`` configured, client IP resolution now reads
  ``X-Forwarded-For`` from the right: it skips entries that match a trusted
  proxy and uses the first entry that does not. It previously used the
  leftmost such entry, which the client controls when the proxy appends to
  the header, so a client could choose ``env['otto.client_ip']``, the address
  ``env['otto.ip_match']`` checks, and the ``Otto::Request#client_ipaddress``
  fallback. ``X-Real-IP`` and ``X-Client-IP`` are read only when
  ``X-Forwarded-For`` is absent and are no longer added to its chain.
  The resolved address is correct only when each trusted proxy appends to
  ``X-Forwarded-For``; see the `forwarded authority guide
  <docs/guides/forwarded-authority.md>`__.
- A forwarded entry that is not a valid IP address (such as ``unknown``, or
  an empty entry, including the one a trailing comma leaves) no longer falls
  back to ``REMOTE_ADDR``. In ``trusted_proxies`` mode the walk
  ends there; in ``trusted_proxy_depth`` mode it applies when that entry is
  the selected hop. The request then has no client IP:
  ``env['otto.ip_match']`` denies every range, ``env['otto.client_ip']`` and
  ``Otto::Request#client_ipaddress`` are nil, and with IP privacy enabled the
  forwarded address headers are deleted. Falling back to the proxy's own
  address made a private or loopback peer the client, which skipped masking,
  left the client's address in ``X-Forwarded-For``, and let ``ip_match``
  test the proxy. Depth mode's short-chain fallback to ``REMOTE_ADDR`` is
  unchanged.
- With IP privacy enabled, a request exempt from masking because its resolved
  client IP is private or loopback now has its ``X-Forwarded-For``,
  ``X-Real-IP`` and ``X-Client-IP`` headers and the ``for=`` values in
  ``Forwarded`` rewritten to that client IP. They were left as received, so
  a public address in them stayed in the Rack env: an entry left of an
  unlisted private proxy hop, or a header sent by an untrusted private peer
  or by any client behind a loopback peer with no proxy trust configured.
  ``Rack::Request#ip``, whose default filter trusts private and loopback
  addresses, returned that public address.
- ``Otto::Utils.normalize_ip`` returns nil for a range (``203.0.113.9/0``,
  ``10.0.0.0/8``, ``203.0.113.9/32``). A forwarded entry written as a range
  is now invalid; before, it was returned as the client IP, masked to the
  range's network address (``0.0.0.0`` for ``/0``), and matched by
  ``ip_match(['0.0.0.0/0'])``. ``Otto::Utils.ip_in_cidrs?`` returns false when
  the client address it is given is a range.
