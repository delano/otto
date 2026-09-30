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
  middleware installed.

- When env has no session, the wrapper still sets ``env['rack.session']`` to
  a session the strategy passed, including an empty Hash, but not to ``nil``,
  ``false``, or the default. ``result.session`` is unchanged: it is the
  session the strategy returned.

Changed
-------

- When a strategy passes no ``session:``, ``StrategyResult.anonymous`` and
  ``AuthStrategy#success`` now default ``result.session`` to a new, empty
  ``StrategyResult::DefaultSession``, a ``Hash`` subclass, instead of a plain
  ``{}``. It still compares equal to ``{}`` and is writable. The route auth
  wrapper recognizes the default by its class, so a strategy that passes an
  empty Hash on purpose has it copied into an empty env, and the check never
  reads a session's contents.

Documentation
-------------

- The authentication guide and reference describe when the route auth wrapper
  sets ``env['rack.session']`` from ``result.session``. The guide adds that
  Logic classes get no env, so on ``auth=noauth``, role, permission, and API
  key routes, and on routes without ``auth=``, ``@context.session`` is a
  separate Hash whose writes are not persisted, and says what to use instead.

- The authentication reference no longer says the route auth wrapper sets
  ``env['otto.user']`` (nothing sets it; the user is
  ``env['otto.strategy_result'].user``), that ``enable_authentication!`` is a
  no-op (it was removed and raises ``NoMethodError``), or that the
  ``auth=role:admin`` syntax was removed (it resolves to the ``role`` strategy,
  and ``RoleStrategy`` checks the session's roles). A ``LoggingHelpers``
  example comment that read ``env['otto.user']`` now reads the strategy
  result.

- The authentication guide has a section on renewing the session id at login
  with rack-session's ``:renew`` option, as protection against session
  fixation. Otto never changes the session id itself. With CSRF protection
  enabled, tokens issued before the renewal stop validating.
