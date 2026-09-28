Fixed
-----

- A new visitor's first form POST no longer fails CSRF validation with 403
  when the session store loads lazily, as rack-session does. On the page that
  issued the token the session id was still nil, so Otto bound the token to a
  random value it stored under ``csrf_session_key``. On the POST the store
  reported its own session id, which Otto read first, so the token was checked
  against a different value. ``Otto::Security::Config#get_or_create_session_id``
  now reads the stored value before the session id. Pages that wrote to the
  session before the token was issued were not affected.

- Session ids are converted with ``to_s`` before they are used as the CSRF
  binding. rack-session returns a ``Rack::Session::SessionId`` object, which
  never compared equal to the ``_otto_session`` cookie, so
  ``CSRFMiddleware`` set that cookie again on every HTML response it added a
  token to.

- For a session that already holds a value under ``csrf_session_key``, tokens
  are now checked against that value instead of the session id. A form
  rendered before the upgrade on such a session fails once; reloading the page
  issues a token that validates. The stored value is session data, so a store
  that renews the session id and keeps the data keeps the binding. Clear the
  session, or delete ``csrf_session_key``, at login to start a new binding.
