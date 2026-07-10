Fixed
-----

- Dynamic static-file serving no longer raises ``FrozenError`` in production
  (delano/otto#185). ``freeze_configuration!`` deep-froze ``@routes_static``
  along with the rest of the routing state, but lazy static-file discovery
  writes into ``routes_static[:GET]`` at request time — after the lazy
  first-request freeze has already run — so the first request for any
  as-yet-uncached asset raised ``FrozenError`` and was turned into a 500. The
  failure was masked in the test suite because the lazy freeze is skipped
  under RSpec. ``routes_static[:GET]`` is now a ``Concurrent::Map`` and is
  excluded from the deep freeze, so it stays writable — and safe under
  concurrent request threads — after configuration is otherwise locked down.
