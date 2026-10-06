Security
--------

- On HTTPS requests, Otto's own CSRF binding cookie is now
  ``__Host-otto_session``, set with ``Secure``, ``Path=/`` and no ``Domain``.
  Browsers that enforce cookie name prefixes accept such a cookie only from a
  secure origin with those attributes, so in those browsers a sibling subdomain
  or a network attacker can no longer plant it. Before, when the session
  provided no binding, a planted ``_otto_session`` (or ``session_id`` or
  ``_session_id``) cookie became the binding, and an attacker holding a token
  for it could forge a login. This covers only Otto's fallback cookie. Behind a
  session middleware the binding is the session's id, so the session cookie can
  still be planted unless it is protected the same way: over HTTPS, configure
  rack-session with a ``__Host-`` key and ``secure: true`` (for example ``use
  Rack::Session::Cookie, key: '__Host-rack.session', secure: true, secrets:
  [...]``), and renew the session id at login with
  ``env['rack.session.options'][:renew] = true``. See
  ``docs/guides/authentication.md``. (#302)

Changed
-------

- On HTTPS requests Otto no longer reads the ``_otto_session``, ``session_id``
  or ``_session_id`` cookies as a CSRF binding. Accepting them as a fallback
  would keep the planting vector, so there is no transition period. After the
  upgrade, a token bound to one of those cookies is rejected once over HTTPS;
  the next token the client fetches is bound to ``__Host-otto_session``.
  Plain HTTP requests keep using ``_otto_session`` as before. The name follows
  Rack's ``request.scheme``: behind a TLS-terminating proxy, Otto must see the
  request as HTTPS (``HTTPS=on``, ``rack.url_scheme``, or
  ``X-Forwarded-Proto``) for the hardening to apply. If Otto sees HTTPS while
  the browser uses HTTP, the browser rejects the cookie and CSRF-protected
  requests get ``403``. (#302)

- A form rendered over HTTP that posts to HTTPS now gets ``403`` on every
  attempt when its binding lives in the cookie: the HTTP page sets
  ``_otto_session``, which the HTTPS request does not read. Migration: serve
  pages with forms over HTTPS, for example by redirecting HTTP to HTTPS and
  enabling HSTS (``Otto::Security::Config#enable_hsts!``). (#302)

- ``CSRFMiddleware`` now sets the binding cookie on every response to a
  request that resolved a CSRF binding, not only on HTML responses. A JSON
  client that fetches a token from an endpoint calling
  ``Config#get_or_create_session_id`` receives the cookie with the token and
  passes on its next POST. The request's resolved binding is recorded in
  ``env['otto.csrf_binding']``, except when it is the session store's own id
  (``session.id``, or ``session['session_id']``): the store's cookie already
  carries that, so it is not copied into the binding cookie on these
  responses. HTML responses still set the binding cookie from any binding, as
  before. (#302)

Fixed
-----

- ``CSRFMiddleware`` now URL-encodes the value of the CSRF binding cookie,
  because Rack URL-decodes cookie values when it reads them. Before, a binding
  that was not a hex token was written as is, and the browser could store a
  different value: an app-set ``session_id`` cookie sent as ``a%3Bb`` (the
  binding ``a;b``) on plain HTTP came back as ``_otto_session=a``, and the
  next CSRF-protected request got ``403``. Hex bindings, including the ones
  Otto generates, are written unchanged. (#302)
