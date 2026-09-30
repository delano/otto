Security
--------

- With ``trusted_proxies`` configured, client IP resolution now reads
  ``X-Forwarded-For`` from the right: it skips entries that match a trusted
  proxy and uses the first entry that does not. It previously used the
  leftmost such entry, which the client controls when the proxy appends to
  the header, so a client could choose ``env['otto.client_ip']``, the address
  ``env['otto.ip_match']`` checks, and the ``Otto::Request#client_ipaddress``
  fallback. ``X-Real-IP`` and ``X-Client-IP`` are read only when
  ``X-Forwarded-For`` is absent or blank and are no longer added to its
  chain. ``trusted_proxy_depth`` already counted from the right.
  **Behavior change**: every proxy between the client and the application
  must now be in ``trusted_proxies``, together with any address a proxy
  appends about itself. Google Cloud's external Application Load Balancer,
  for example, appends the client's address and then its forwarding rule's
  address. If one is missing, the unlisted address nearest the application
  becomes the client IP for every request through it: rate-limit keys and
  ``otto.privacy.hashed_ip`` collapse onto it, ``ip_match`` tests it, and a
  private or loopback one exempts the request from masking. 2.12.0 took the
  leftmost untrusted entry, so a missing inner hop went unnoticed. A request
  whose ``X-Forwarded-For`` holds only trusted proxies now resolves to
  ``REMOTE_ADDR`` even when ``X-Real-IP`` names the client.
  **Migration:** list every proxy address, CDN edge ranges and load balancer
  addresses included, in ``trusted_proxies``, and configure each proxy to
  append the address it received the request from to ``X-Forwarded-For``
  (nginx: ``proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;``)
  or to replace a client-supplied value. A proxy that sets only ``X-Real-IP``
  must also append to or replace ``X-Forwarded-For``. See `How enumerated
  proxy trust resolves the client IP
  <docs/guides/forwarded-authority.md#how-enumerated-proxy-trust-resolves-the-client-ip>`__.
- A forwarded entry that is not a valid IP address (such as ``unknown``, or
  an empty entry, including the one a trailing comma leaves) no longer falls
  back to ``REMOTE_ADDR``. In ``trusted_proxies`` mode the walk ends there;
  in ``trusted_proxy_depth`` mode it applies when that entry is the selected
  hop. The request then has no client IP: ``env['otto.ip_match']`` denies
  every range, ``env['otto.client_ip']`` and
  ``Otto::Request#client_ipaddress`` are nil, and with IP privacy enabled
  ``X-Forwarded-For``, ``X-Real-IP`` and ``X-Client-IP`` are deleted and each
  ``for=`` value in ``Forwarded`` becomes ``unknown``, keeping its ``proto=``,
  ``host=`` and ``by=``. A request with no ``REMOTE_ADDR`` takes the same
  path, and its ``Forwarded`` header is now rewritten the same way instead of
  deleted. ``Otto::Request#ip`` still returns ``REMOTE_ADDR``, the proxy,
  on purpose: rate limiters key on the request IP, and
  rack-attack skips a throttle whose discriminator is nil. Use ``ip_match``,
  not ``req.ip``, for access decisions. Falling back to the proxy's own
  address made a private or loopback peer the client, which skipped masking,
  left the client's address in ``X-Forwarded-For``, and let ``ip_match``
  test the proxy. **Behavior change** for ``trusted_proxy_depth``, whose
  invalid-target fallback to ``REMOTE_ADDR`` was documented. Depth mode's
  short-chain fallback to ``REMOTE_ADDR`` is unchanged.
- With IP privacy enabled, a request exempt from masking because its resolved
  client IP is private or loopback now has its ``X-Forwarded-For``,
  ``X-Real-IP`` and ``X-Client-IP`` headers and the ``for=`` values in
  ``Forwarded`` rewritten to that client IP. They were left as received, so
  a public address in them stayed in the Rack env: an entry left of an
  unlisted private proxy hop, or a header sent by an untrusted private peer
  or by any client behind a loopback peer with no proxy trust configured.
  ``Rack::Request#ip``, whose default filter trusts private and loopback
  addresses, returned that public address. **Behavior change**: code behind
  a private or loopback peer that read these headers, or called a plain
  ``Rack::Request#ip``, now sees the resolved client IP. **Migration:** to
  get the client's address from a local reverse proxy, list that proxy in
  ``trusted_proxies`` so Otto resolves the client (and masks a public one).
- ``Otto::Utils.normalize_ip`` returns nil for a range (``203.0.113.9/0``,
  ``10.0.0.0/8``, ``203.0.113.9/32``). A forwarded entry written as a range
  is now invalid; before, it was returned as the client IP, masked to the
  range's network address (``0.0.0.0`` for ``/0``), and matched by
  ``ip_match(['0.0.0.0/0'])``. ``Otto::Utils.ip_in_cidrs?`` returns false when
  the client address it is given is a range.
