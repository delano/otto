Fixed
-----

- A new visitor's first form POST no longer fails CSRF validation with 403
  when the session store loads lazily, as rack-session does. On the page that
  issued the token the session id was still nil, so Otto bound the token to a
  random value it stored under ``csrf_session_key``. That write made the store
  mint a session id, and on the POST Otto read that id first, so the token was
  checked against a different value.
  ``Otto::Security::Config#get_or_create_session_id`` now reads back the id
  the store minted during the write and binds the token to it. Pages that
  wrote to the session before the token was issued were not affected. (#295)

- Session ids are converted with ``to_s`` before they are used as the CSRF
  binding, and ``get_or_create_session_id`` always returns a String.
  rack-session returns a ``Rack::Session::SessionId`` object, which never
  compared equal to the ``_otto_session`` cookie, so ``CSRFMiddleware`` set
  that cookie again on every HTML response it added a token to. (#295)

- The binding still follows the session id. A store that renews the id, for
  example rack-session's ``renew`` option at login, invalidates the tokens
  issued before the renewal. (#295)
