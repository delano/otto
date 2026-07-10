Security
--------

- Dynamic-route and static-file dispatch now normalize the request path the
  same way literal matching and ``Otto::CaddyTLS::LocalhostGuard`` do (#187).
  Previously the dynamic matcher and the ``safe_file?`` branch matched against
  the raw (unescape-only) path while literal lookup used the trailing-slash-
  stripped, UTF-8-scrubbed path. Two divergences resulted: dynamic routes were
  stricter about trailing slashes than literal routes (so ``/show/123/`` missed
  a ``/show/:id`` route that ``/about/`` would hit as a literal), and invalid
  UTF-8 bytes scrubbed for the guard survived into the dynamic matcher and the
  static branch — the guard-bypass class ``normalize_path`` exists to close. All
  dispatch paths now share the single normalization; root still routes correctly
  (a catch-all ``/*`` continues to match ``/``).
