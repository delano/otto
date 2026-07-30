Added
-----

- ``AuthFailure`` now carries a ``terminal`` flag (``terminal?`` predicate),
  and ``AuthStrategy#failure`` accepts ``terminal: true``. A terminal failure
  means "this request explicitly presented credentials and they were examined
  and rejected — do not consult further strategies." ``RouteAuthWrapper``
  halts the chain on a terminal failure and renders the 401 with that
  failure's reason, regardless of strategy order, so mixed
  credentialed/anonymous chains (``auth=basicauth,noauth``) can fail closed on
  invalid credentials instead of silently proceeding as anonymous. Plain
  failures keep the existing OR fallthrough, so credential-less requests still
  reach ``noauth``, and noauth-only routes are unaffected. (#220)

Changed
-------

- ``RouteAuthWrapper`` multi-strategy chains now treat an anonymous success
  (a ``StrategyResult`` with no user, e.g. from ``noauth``) as a held
  fallback rather than an immediate win: the rest of the chain still runs so
  a later credentialed strategy can reject explicitly presented credentials
  terminally — this is what makes terminal failures order-independent. The
  fallback wins once the chain completes without an authenticated success or
  terminal failure, preserving OR semantics for requests without
  credentials. Consequently, in a chain like ``auth=noauth,apikey`` a later
  authenticated success now wins over an earlier anonymous one. (#220)

AI Assistance
-------------

- Design, implementation, and regression specs written with AI assistance.
  (#220)
