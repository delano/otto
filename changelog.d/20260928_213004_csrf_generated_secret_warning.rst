Fixed
-----

- Apps that enable CSRF protection without ``OTTO_CSRF_SECRET`` or
  ``csrf_secret=`` no longer return 500 for every HTML response outside
  production. ``Otto#call`` freezes the configuration on the first request,
  and the first CSRF token generation then recorded on the frozen
  ``Otto::Security::Config`` that the generated-secret warning had been
  logged, which raised ``FrozenError``. The once-only state now lives in an
  object that stays writable after the freeze. With CSRF enabled, the warning
  is logged when the configuration is frozen. A frozen config with CSRF
  protection disabled logs it the first time ``CSRFHelpers#csrf_token`` or
  ``generate_csrf_token`` signs a token (it raised ``FrozenError`` before).
  The warning is logged once per config, also when several threads generate
  the first tokens at the same time. Specs under RSpec did not hit the error
  because Otto skips the lazy freeze when RSpec is loaded. (#297)

Changed
-------

- The generated-secret warning and ``CSRF_SECRET_REQUIRED_MESSAGE`` no longer
  say that a generated secret is not valid across workers in general. Workers
  forked after the secret was generated, as in a preloaded app, share it.
  Workers that load the app themselves (cluster mode without preload),
  processes started separately, other hosts and restarts each generate their
  own secret and reject each other's tokens, and the messages now say so. The
  warning text is in
  ``Otto::Security::Config::CSRF_GENERATED_SECRET_WARNING``. (#297)
