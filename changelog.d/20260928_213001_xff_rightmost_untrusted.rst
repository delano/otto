Security
--------

- With ``trusted_proxies`` configured, client IP resolution now reads
  ``X-Forwarded-For`` from the right: it skips entries that match a trusted
  proxy and uses the first entry that does not. It previously used the
  leftmost such entry, which the client controls when the proxy appends to
  the header, so a client could choose ``env['otto.client_ip']``, the address
  ``env['otto.ip_match']`` checks, and the ``Otto::Request#client_ipaddress``
  fallback. An entry that is not a valid IP address now ends the walk and
  ``REMOTE_ADDR`` is used. ``X-Real-IP`` and ``X-Client-IP`` are read only
  when ``X-Forwarded-For`` is absent and are no longer added to its chain.
  The resolved address is correct only when each trusted proxy appends to
  ``X-Forwarded-For``; see the `forwarded authority guide
  <docs/guides/forwarded-authority.md>`__. ``trusted_proxy_depth`` is
  unchanged.
