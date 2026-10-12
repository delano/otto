Fixed
-----

- A CSRF-protected request now gets ``403`` instead of ``500`` when its token
  is a parameter that Rack parses into an Array or a Hash (``_csrf_token[]=``
  or ``_csrf_token[k]=``), a token with invalid UTF-8 bytes, a signature with
  as many characters as a valid one but more bytes (such as 64 ``é``), or an
  ``ASCII-8BIT`` header token with non-ASCII bytes when the binding has
  non-ASCII characters. The CSRF check raised for each of these, and Otto
  logged an unhandled error. The request was refused either way; only the
  status was wrong. A body that Rack cannot parse, such as
  ``_csrf_token=%ZZ``, still gets ``500``, with or without CSRF
  protection. (#PR)

- ``Otto::Security::Config#verify_csrf_token`` now returns ``false`` for a
  token that is not a ``String`` or that holds non-ASCII bytes, since a valid
  token is hex. Signatures are compared with ``Rack::Utils.secure_compare``,
  which compares lengths in bytes, in place of a loop that compared lengths in
  characters. ``CSRFEnforcementWrapper`` rejects such a token before it
  resolves the CSRF binding, as it already did for a blank one, so the check
  does not create a session or a binding for it. (#PR)
