Fixed
-----

- HEAD requests no longer return 500 once the configuration is frozen. When
  any ``HEAD`` route was declared, the router merged the GET tables into the
  registered HEAD tables (``routes_literal[:HEAD]`` and ``routes[:HEAD]``) on
  every HEAD request. After the first request outside the test suite those
  tables are frozen, so every HEAD request raised ``FrozenError``. The router
  now looks up the HEAD route first and falls back to the GET route without
  changing either table.

- A declared ``HEAD`` literal route now handles HEAD requests for its path.
  The merge let the ``GET`` route for the same path replace it, and it grew
  ``routes[:HEAD]`` on every HEAD request while the configuration was not yet
  frozen. Dynamic HEAD routes are still tried before dynamic GET routes. A
  declared ``HEAD`` route uses its own options and does not inherit ``auth=``
  or ``role=`` from the ``GET`` route for the same path. A HEAD request for a
  path with only a ``GET`` route falls back to that route, including its
  ``auth=``.
