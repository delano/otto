Added
-----

- Depth mode (``Otto::Security::Config#trusted_proxy_depth``) can now count hops
  from a configurable forwarded header, via a new ``#trusted_proxy_header``
  accessor: ``X-Forwarded-For`` (default), ``Forwarded`` (RFC 7239), or ``Both``
  (``Forwarded`` when it carries a ``for=``, otherwise ``X-Forwarded-For``).
  Settable through ``Otto::Security::Configurator#configure`` and the
  ``trusted_proxy_header`` option of ``Otto.new`` / ``configure_security``; an
  unrecognized value raises ``ArgumentError`` at assignment. This reaches parity
  with OneTimeSecret's ``site.network.trusted_proxy.header``. (delano/otto#150,
  onetimesecret#3436)

AI Assistance
-------------

- RFC 7239 ``Forwarded`` / ``Both`` depth-header support designed and implemented
  with AI pair programming, with per-header, quoted-IPv6, and ``Both``-precedence
  test coverage.
