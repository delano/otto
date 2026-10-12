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

Changed
-------

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
