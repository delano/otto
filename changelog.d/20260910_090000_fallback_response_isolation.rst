Security
--------

- ``Otto#not_found=`` and ``Otto#server_error=`` static Rack triples are now
  copied per request instead of being returned by reference. Cookie
  middleware (rack-session, Otto's CSRF middleware, anything calling
  ``Rack::Utils.set_cookie_header!``) writes response headers in place, so a
  shared triple accumulated every ``Set-Cookie`` committed on earlier 404/500
  responses and replayed them to later clients. Headers keep their class,
  Array-valued headers and Array bodies are copied, and a frozen triple yields
  a writable copy. (#272)

Added
-----

- ``Otto#not_found=`` and ``Otto#server_error=`` accept a callable
  (``call(env)``; ``server_error`` also receives the exception when the
  callable declares a second positional parameter) that builds a fresh
  response per request. ``env['otto.error_id']`` carries the logged
  correlation id. A callable that raises or returns a non-triple is logged
  and replaced by the built-in secure error response. Both writers reject
  values that are neither a Rack triple (Integer status, Hash-like headers,
  body responding to ``each`` or ``call``) nor callable with
  ``ArgumentError``. (#272)
