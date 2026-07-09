Fixed
-----

- Reverse URI generation (``Otto#uri``) no longer corrupts when the same
  handler/target is mounted at multiple paths (#190). Previously
  ``@route_definitions`` was keyed only by the definition string, so
  duplicate targets overwrote each other and ``uri()`` returned whichever
  path loaded last. All routes per definition are now kept (exposed via
  ``Otto#routes_by_definition``) and ``uri()`` picks the route whose path
  placeholders match the params given — e.g. with ``GET /users/:id
  Account#show`` and ``GET /me Account#show``, ``uri('Account#show', id: 5)``
  returns ``/users/5`` and ``uri('Account#show')`` returns ``/me``.
  ``Otto#route_definitions`` now deterministically keeps the first-loaded
  route per definition, and loading a duplicate definition logs a warning.
