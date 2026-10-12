Fixed
-----

- A CSRF-protected request with a malformed token now gets ``403`` instead of
  ``500``. The CSRF check raised, and Otto logged an unhandled error, for a
  token parameter that Rack parses into an Array or a Hash
  (``_csrf_token[]=`` or ``_csrf_token[k]=``), for a token with invalid UTF-8
  bytes, for a signature with as many characters as a valid one but more
  bytes (such as 64 ``é``), and for an ``ASCII-8BIT`` header token with
  non-ASCII bytes when the binding has non-ASCII characters. The request was
  refused either way; only the status was wrong. (#PR)

- ``Otto::Security::Config#verify_csrf_token`` now returns ``false`` for a
  token that is not a ``String`` or that holds non-ASCII bytes, since a valid
  token is hex. Signatures are compared with ``Rack::Utils.secure_compare``,
  which compares lengths in bytes, in place of a loop that compared lengths in
  characters. ``CSRFEnforcementWrapper`` rejects such a token before it
  resolves the CSRF binding, as it already did for a blank one, so the check
  does not create a session or a binding for it. (#PR)
