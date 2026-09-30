Fixed
-----

- ``RouteAuthWrapper`` no longer replaces an existing ``env['rack.session']``
  with the strategy result's session. ``NoAuthStrategy``, ``RoleStrategy``,
  ``PermissionStrategy``, and ``APIKeyStrategy`` return the empty Hash that
  ``StrategyResult.anonymous`` and ``AuthStrategy#success`` use as a default,
  and that Hash used to overwrite the session installed by the session
  middleware. On ``auth=noauth`` routes, an ``auth=session,noauth``
  fall-through, and role, permission, and API key routes the handler received
  a bare Hash. rack-session then raised ``NoMethodError`` (undefined method
  ``options`` for Hash) while committing the session, and the handler's
  session writes were lost. The handler now receives the session object the
  middleware installed. (#298)

- When env has no session, or holds only the stand-in Hash that
  ``Otto::Request#session`` installs when no session middleware ran, the
  wrapper sets ``env['rack.session']`` to the strategy's session (anything
  but ``nil`` or ``false``), as before. Otto's CSRF check reads the session
  that way before authentication, so strategy-owned sessions keep their
  writes on CSRF-checked requests. (#298)

Changed
-------

- Behind a session middleware, a strategy's ``result.session`` no longer
  replaces ``env['rack.session']``. A custom strategy that returned its own
  session, or wrote into the default one, is visible only as
  ``env['otto.strategy_result'].session`` there. Migration: write to
  ``env['rack.session']``, or pass ``session: env['rack.session']`` to
  ``success``. (#298)

- ``Otto::Request#session`` installs an ``Otto::Request::DefaultSession`` (an
  empty ``Hash`` subclass) instead of a plain ``{}`` when env has no
  session. (#298)

Documentation
-------------

- The authentication guide and reference describe when the route auth wrapper
  sets ``env['rack.session']`` from ``result.session``. The guide adds that
  Logic classes get no env, so behind a session middleware on ``auth=noauth``,
  role, permission, and API key routes, and on any route without ``auth=``,
  ``@context.session`` is a separate Hash whose writes are not persisted, and
  says what to use instead. (#298)

- The authentication reference no longer says the route auth wrapper sets
  ``env['otto.user']`` (nothing sets it; the user is
  ``env['otto.strategy_result'].user``), that ``enable_authentication!`` is a
  no-op (it was removed and raises ``NoMethodError``), or that the
  ``auth=role:admin`` syntax was removed (it resolves to the ``role`` strategy,
  and ``RoleStrategy`` checks the session's roles). A ``LoggingHelpers``
  example comment that read ``env['otto.user']`` now reads the strategy
  result. (#298)

- The authentication guide has a section on renewing the session id at login
  with rack-session's ``:renew`` option, as protection against session
  fixation. Otto never changes the session id itself. With CSRF protection
  enabled, tokens issued before the renewal stop validating. (#298)

- The authentication reference's multi-strategy flow no longer says the first
  success wins and that 401 is returned only when every strategy fails. It now
  describes the held anonymous fallback, terminal failures, and the 403, 401
  and 302 outcomes. Its role extraction order now includes object-backed users
  (``#roles``, then ``#role``). (#298)

- The session-renewal section of the authentication guide says fixation lets
  the attacker in with a server-side store such as ``Rack::Session::Pool``
  but not with ``Rack::Session::Cookie``, recommends redirecting after login
  because a form rendered in the login response carries a token bound to the
  old id, and notes that its CSRF text assumes #295. The reference's
  ``auth=noauth,apikey`` example gives the 302 for non-JSON requests, and the
  multi-strategy notes in ``AGENTS.md`` match the code. (#298)
