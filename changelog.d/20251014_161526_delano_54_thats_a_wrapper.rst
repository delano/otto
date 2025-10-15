Changed
-------

- Renamed MiddlewareStack#build_app to #wrap to better reflect per-request behavior
  (wraps base app in middleware layers on each request, not a one-time initialization)
