Security
--------

- Behind ``Rack::Session::Pool``, a session cookie value the store holds no
  session for no longer becomes the CSRF binding. Until a rack-session session
  loads, its id is the raw cookie value, and Otto read that id without loading
  the session, so an attacker who could set cookies for the victim's browser
  could plant ``rack.session=`` with any value, request a form with it, and
  forge a login with the token. Otto now reads the session before it uses
  ``session.id``, which loads it; ``Pool`` then replaces an unknown id with a
  new session. A request that sends no session cookie has nothing to load, so
  the read does not create a session. A planted copy of a session the store
  does hold still works, as before; see "Protect the cookie that carries the
  CSRF binding" in ``docs/guides/authentication.md``. (#PR)

- A cross-site POST to a ``csrf=exempt`` route that returns HTML no longer
  replaces the victim's CSRF binding. Such a POST arrives without the
  ``SameSite=Lax`` binding cookie, but the browser keeps a cookie set on the
  response to it. ``CSRFMiddleware`` minted a binding for it, set it as the
  binding cookie and injected a token, so the forms the victim had open got
  ``403``. Behind rack-session, when the browser did not send the session
  cookie either, a new session was committed over the victim's. On an unsafe
  request Otto now neither creates a binding nor sets the binding cookie, and
  injects a token only when the request already has a binding. (#PR)

- ``CSRFMiddleware`` no longer copies the session's id into the binding
  cookie on HTML responses. #302 stopped the copy on other responses; HTML
  responses still copied ``session.id``, ``session['session_id']`` or a
  binding read from a cookie into ``_otto_session`` or
  ``__Host-otto_session``. A victim whose browser held a planted copy of the
  attacker's session cookie then kept the attacker's session id in
  ``__Host-otto_session``, which Otto sets without ``Expires``. Once the
  session cookie was gone, for example at the end of its ``expire_after``
  lifetime, that id was the binding again and a token the attacker held for
  it was accepted. Both paths now share one rule and one code path: the
  binding cookie is set only on responses to safe requests, and only to a
  binding Otto minted or read from ``csrf_session_key``. (#PR)

Added
-----

- ``Otto::Security::Config#existing_session_id(request)`` returns the CSRF
  binding the request already has, from the same sources as
  ``get_or_create_session_id``, or ``nil``. It never mints a binding, writes
  to the session or sets ``env['otto.csrf_binding']``. (#PR)

Changed
-------

- An HTML response to an unsafe request that has no binding, such as a
  ``csrf=exempt`` callback that another site posts to, now carries no CSRF
  token, and ``CSRFHelpers#csrf_token`` returns ``nil`` there instead of
  minting a binding. Behind a session middleware, a handler that writes to the
  session first still gets a token bound to the new session. Migration: answer
  the POST with a redirect and render the form on the page it redirects to.
  (#PR)

- HTML responses no longer set ``_otto_session`` or ``__Host-otto_session``
  to the session's id, ``session['session_id']``, or a binding read from the
  app's ``session_id`` or ``_session_id`` cookie. Behind a session middleware
  the store's cookie carries the binding. A store whose cookie does not come
  back, such as rack-session with ``secure: true`` while Rack sees the request
  as HTTP, kept no session between requests, but the copy kept CSRF tokens
  valid; CSRF-protected requests now get ``403`` too. Fix the store's
  configuration so its cookie is set (see the authentication guide). (#PR)

- Without a session middleware, a token bound to an auth strategy's session
  that responds to ``id`` or holds a ``'session_id'`` key is now rejected with
  ``403`` on the next request. The CSRF check runs before authentication, so
  it read the copy of that id in the binding cookie, which HTML responses no
  longer set. Migration: run a session middleware, or return a strategy
  session without an id, in which Otto stores its own binding under
  ``csrf_session_key``. (#PR)

- With ``Rack::Session::Pool``, a logout that drops the session (``:drop``)
  and renders a form in the same response now issues a token that the next
  request rejects with ``403``: the dropped id stays in the client's cookie,
  and loading it gives a new session. Migration: respond to the logout with a
  redirect and render the form on the page it redirects to. (#PR)

- Otto now loads the session when it resolves the CSRF binding (on HTML
  responses and CSRF-checked requests). rack-session commits a session that
  was loaded, so ``Rack::Session::Cookie`` sets its cookie again on those
  responses, re-encrypted with the same data, and a store configured with
  ``expire_after`` renews the cookie's expiry. ``Pool`` sets its cookie only
  when the id changed. (#PR)

Fixed
-----

- A request that fails the CSRF check no longer creates a binding. Validation
  called ``get_or_create_session_id``, so a request without one had a binding
  minted and written to the session, though no token can verify against a new
  binding. Behind rack-session the rejected POST then committed a new session
  and set its cookie on the ``403``. Validation now reads the binding with
  ``existing_session_id``. (#PR)
