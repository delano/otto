Fixed
-----

- HEAD requests no longer return 500 once the configuration is frozen. When
  any ``HEAD`` route was declared, the router merged the GET tables into the
  registered HEAD tables (``routes_literal[:HEAD]`` and ``routes[:HEAD]``) on
  every HEAD request. After the first request outside the test suite those
  tables are frozen, so every HEAD request raised ``FrozenError``. The router
  now looks up the HEAD route first and falls back to the GET route without
  changing either table. (#294)

- A declared ``HEAD`` literal route now handles HEAD requests for its path.
  The merge let the ``GET`` route for the same path replace it, and it grew
  ``routes[:HEAD]`` on every HEAD request while the configuration was not yet
  frozen. Dynamic HEAD routes are still tried before dynamic GET routes. A
  declared ``HEAD`` route uses its own options and does not inherit ``auth=``
  or ``role=`` from the ``GET`` route for the same path. A HEAD request for a
  path with only a ``GET`` route falls back to that route, including its
  ``auth=``. (#294)

- Responses to HEAD requests now have an empty body. A HEAD request that fell
  back to a ``GET`` route returned the GET body, which ``Rack::Lint`` rejects
  with "Response body was given for HEAD request, but should be empty".
  ``Otto#call`` now replaces the body after dispatch and error handling and
  keeps the status and headers, including a ``content-length`` the handler
  set. When the handler's body is a plain Array and the response has no
  ``content-length``, no ``transfer-encoding`` and a status that allows
  content, ``Otto#call`` sets ``content-length`` from that Array, so the HEAD
  response advertises the length a GET would send; Puma and
  ``Rack::ContentLength`` would otherwise compute 0 from the empty body. The
  replacement body has no ``#to_ary`` and closes the original when the server
  closes it, as it would for GET, so an error raised by that close surfaces
  there, not from ``Otto#call`` or from middleware such as ``Rack::ETag``.
  This covers handler, ``/404``, not-found and error responses. Request
  completion hooks receive the response with the empty body. (#294)

- Static mounts and the public directory now answer HEAD requests. They
  answered only GET, so a HEAD request for an asset fell through to the
  dynamic routes and, when none matched, to not found. A HEAD response
  carries the headers a GET would get, including ``content-length``, and an
  empty body. Requests with other methods still skip the static stages.
  (#294)
