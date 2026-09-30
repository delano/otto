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

- Responses to HEAD requests now have an empty body, as the Rack SPEC
  requires. A HEAD request that fell back to a ``GET`` route returned the GET
  body, which ``Rack::Lint`` rejects. ``Otto#call`` now drops the body after
  dispatch and error handling, as ``Rack::Head`` does: it closes the original
  body and keeps the status and headers, including a ``content-length`` the
  handler set. This covers handler, ``/404``, not-found and error responses.
  Request completion hooks receive the response with the empty body.
