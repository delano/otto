Fixed
-----

- Apps that enable CSRF protection without ``OTTO_CSRF_SECRET`` or
  ``csrf_secret=`` no longer return 500 for every HTML response outside
  production. ``Otto#call`` freezes the configuration on the first request,
  and the first CSRF token generation then recorded on the frozen
  ``Otto::Security::Config`` that the generated-secret warning had been
  logged, which raised ``FrozenError``. The warning is now logged once when
  the configuration is frozen, and token generation on a frozen config does
  not write to it. A frozen config with CSRF protection disabled no longer
  logs the warning when ``CSRFHelpers#csrf_token`` mints a token (it raised
  ``FrozenError`` before). Specs under RSpec did not hit the error because
  Otto skips the lazy freeze when RSpec is loaded.
