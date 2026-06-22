Added
-----

- Depth mode (``Otto::Security::Config#trusted_proxy_depth``) can now select
  which forwarded header it counts hops from, via a new ``#trusted_proxy_header``
  accessor: ``X-Forwarded-For`` (default), ``Forwarded`` (RFC 7239), or ``Both``
  (RFC 7239 when it carries a ``for=``, otherwise ``X-Forwarded-For`` — a
  fallback, never a merge). Settable through
  ``Otto::Security::Configurator#configure`` (``trusted_proxy_header:``) and the
  ``trusted_proxy_header`` option of ``Otto.new`` / ``configure_security``. The
  RFC 7239 parser reads each forwarded-element's ``for=`` case-insensitively,
  unquotes it, and handles quoted IPv6 with a port, obfuscated / ``unknown``
  identifiers, and multiple/comma-joined ``Forwarded`` values. The
  ``trusted_proxy_header`` value itself is matched case-insensitively (whitespace
  ignored) and stored canonicalized, so a hand-edited ``forwarded`` / ``both``
  works; a genuinely unrecognized value raises ``ArgumentError`` at assignment
  rather than silently resolving from a default header, surfacing typos at config
  time. Depth's safety properties are preserved across all modes: raw position
  counting (junk cannot shift the index), short-chain → ``REMOTE_ADDR`` fallback,
  and the single-value ``X-Real-IP`` / ``X-Client-IP`` headers still ignored. This
  reaches parity with OneTimeSecret's ``site.network.trusted_proxy.header`` so the
  downstream depth path can be deleted. (delano/otto#150, onetimesecret#3436)

AI Assistance
-------------

- RFC 7239 ``Forwarded`` / ``Both`` depth-header support designed and implemented
  with AI pair programming, grounded in the OneTimeSecret reference resolver, with
  per-header / quoted-IPv6 / ``Both``-precedence / raw-position-counting test
  coverage.
