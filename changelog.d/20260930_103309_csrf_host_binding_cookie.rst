Security
--------

- On HTTPS requests, the CSRF binding cookie is now ``__Host-otto_session``,
  set with ``Secure``, ``Path=/`` and no ``Domain``. Browsers accept such a
  cookie only from a secure origin with those attributes, so a sibling
  subdomain or a network attacker can no longer plant the binding. Before,
  when the session provided no binding, a planted ``_otto_session`` (or
  ``session_id`` or ``_session_id``) cookie became the binding, and an
  attacker holding a token for it could forge a login. (#302)

Changed
-------

- On HTTPS requests Otto no longer reads the ``_otto_session``, ``session_id``
  or ``_session_id`` cookies as a CSRF binding. Accepting them as a fallback
  would keep the planting vector, so there is no transition period. After the
  upgrade, an HTTPS client whose binding lived only in ``_otto_session`` gets
  ``403`` once on a form rendered before the deploy; the next page load sets
  ``__Host-otto_session`` and issues a token that validates. Plain HTTP
  requests keep using ``_otto_session`` as before. The name follows Rack's
  ``request.scheme``: behind a TLS-terminating proxy, Otto must see the
  request as HTTPS (``HTTPS=on``, ``rack.url_scheme``, or
  ``X-Forwarded-Proto``) for the hardening to apply. If Otto sees HTTPS while
  the browser uses HTTP, the browser rejects the cookie and CSRF-protected
  requests get ``403``. (#302)
