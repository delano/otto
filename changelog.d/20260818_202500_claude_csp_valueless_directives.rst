Fixed
-----

- Prevent request-scoped CSP extras from invalidating valueless directives,
  including ``upgrade-insecure-requests`` and ``block-all-mixed-content``.
  Unsupported extras are ignored and logged; valid extras for other
  directives continue to apply. (#243)
