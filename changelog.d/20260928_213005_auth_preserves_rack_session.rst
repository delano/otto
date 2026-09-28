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
  a session the strategy hands back, but no longer to the empty Hash default.
  ``result.session`` is unchanged: it is the session the strategy returned.
