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
  <docs/guides/forwarded-authority.md#how-enumerated-proxy-trust-resolves-the-client-ip>`__. (#292)

- A forwarded entry that is not a valid IP address (such as ``unknown``, or
  an empty entry, including the one a trailing comma leaves) no longer falls
  back to ``REMOTE_ADDR``. In ``trusted_proxies`` mode the walk ends there;
  in ``trusted_proxy_depth`` mode it applies when that entry is the selected
  hop. The request then has no client IP: ``env['otto.ip_match']`` denies
  every range, ``env['otto.client_ip']`` and
  ``Otto::Request#client_ipaddress`` are nil, and with IP privacy enabled
  ``X-Forwarded-For``, ``X-Real-IP`` and ``X-Client-IP`` are deleted and
  ``Forwarded`` loses its ``for=`` pairs but keeps ``proto=``, ``host=`` and
  ``by=`` (it is deleted only if nothing else is left). A request with no
  ``REMOTE_ADDR`` takes the same path; its ``Forwarded`` header used to be
  deleted outright. ``Otto::Request#ip`` and a plain ``Rack::Request#ip``
  still return ``REMOTE_ADDR``, the proxy, on purpose: rate limiters key on
  the request IP, and rack-attack skips a throttle whose discriminator is
  nil. Use ``ip_match``,
  not ``req.ip``, for access decisions. Falling back to the proxy's own
  address made a private or loopback peer the client, which skipped masking,
  left the client's address in ``X-Forwarded-For``, and let ``ip_match``
  test the proxy. **Behavior change** for ``trusted_proxy_depth``, whose
  invalid-target fallback to ``REMOTE_ADDR`` was documented. Depth mode's
  short-chain fallback to ``REMOTE_ADDR`` is unchanged. **Migration:** a
  trusted proxy that writes ``unknown`` where the client address belongs
  now leaves every request through it without a client IP; configure it to
  append the address it received the request from. (#292)

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
  ``Rack::Request#ip``, now sees the resolved client IP. Behind a local
  reverse proxy with no trusted proxy configured, that is ``127.0.0.1`` for
  every client, so a rate limiter keyed on ``Rack::Request#ip`` after
  ``IPPrivacyMiddleware`` (rack-attack's request is a ``Rack::Request``) puts
  every client in the loopback bucket. It used to read each client's own,
  unverified ``X-Forwarded-For`` value. **Migration:** to get the client's
  address from a local reverse proxy, list that proxy in ``trusted_proxies``
  so Otto resolves the client (and masks a public one). (#292)

- The ``Forwarded`` ``for=`` rewrite (masking, the exemption above, and the
  no-client-IP removal) now finds ``for=`` after every separator Rack 3.2.7
  accepts: whitespace, including a leading tab, and a closing quote, as in
  ``by="x" for=198.51.100.7``. It used to find it only at the start or after
  a comma or semicolon, so a client-chosen ``for=`` could survive and be
  returned by ``Rack::Request#ip``. The result is re-read with
  ``Rack::Utils.forwarded_values``; if another ``for=`` value survives, or
  Rack cannot parse the header (Rack rejects parameters other than ``by``,
  ``for``, ``host`` and ``proto``, so an RFC 7239 extension parameter is
  enough), the header is deleted. The first deletion in a process is logged
  at warn and later ones at debug, since a header like that arrives on every
  request and any client can send one. (#292)

- ``Otto::Utils.normalize_ip`` returns nil for a value written as a range,
  such as ``203.0.113.9/0`` or ``10.0.0.0/8``, so a forwarded entry written
  that way is now invalid and the request has no client IP. 2.12.0 took it
  for an address. With ``trusted_proxies: ['10.0.0.0/8']``: a public range
  was returned as the client IP and masked to its network address
  (``203.0.113.9/0`` became ``0.0.0.0``, ``203.0.113.9/32`` became
  ``203.0.113.0``); a loopback or private range outside the trusted list was
  exempted from masking and written to ``REMOTE_ADDR`` and
  ``otto.client_ip`` as the literal string (``127.0.0.1/8``, which
  ``ip_match(['127.0.0.0/8'])`` accepted); and a range inside the trusted
  list (``10.0.0.0/8``) was skipped as a trusted hop.
  ``Otto::Utils.ip_in_cidrs?`` returns false when the client address it is
  given is a range, as a string or as an ``IPAddr`` whose prefix is shorter
  than a host address (``IPAddr.new('203.0.113.0/24')`` used to match
  ``203.0.0.0/16``). (#292)

- With IP privacy enabled, vendor headers that carry the client address are
  now masked along with ``REMOTE_ADDR``: ``CF-Connecting-IP``,
  ``CF-Connecting-IPv6``,
  ``True-Client-IP``, ``Fastly-Client-IP``, ``Fly-Client-IP``,
  ``X-Azure-ClientIP``, ``X-Azure-SocketIP``, ``CloudFront-Viewer-Address``,
  ``X-Vercel-Forwarded-For``, ``X-Original-Forwarded-For``,
  ``X-Cluster-Client-IP`` and ``X-AppEngine-User-IP``
  (``Otto::Utils::VENDOR_CLIENT_ADDRESS_HEADERS``). They were left raw while
  ``REMOTE_ADDR`` was masked, so the public client address stayed in the Rack
  env. They are rewritten to the resolved client IP on the private/loopback
  exemption, deleted when no client IP resolves, and masked in the env a
  custom geo resolver sees. Otto still never reads the client IP from them.
  **Behavior change**: code that read one of these headers to get the
  client address now sees the masked (or exempt) address. **Migration:**
  configure ``trusted_proxies`` for the CDN so Otto resolves the client from
  ``X-Forwarded-For``, and read ``req.ip`` or ``env['otto.ip_match']``; use
  the ``:audit`` profile if the raw address is required. (#292)
