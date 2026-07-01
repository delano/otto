Security
--------

- Security middleware enabled via the ``otto.security.*`` Configurator surface
  (and ``otto.security.configure``) after ``Otto.new`` now takes effect on the
  running request chain. Previously it registered in the stack but never entered
  the built app, silently leaving CSRF, request validation, rate limiting, and
  CSP reporting unenforced when configured that way.

Fixed
-----

- ``Otto::Security::CSP::ReportMiddleware`` no longer masks downstream errors on
  non-report requests as an empty ``204``; its rescue now guards report handling
  only, so ordinary request failures reach Otto's normal error handling.

AI Assistance
-------------

- Middleware-stack rebuild fix and report-receiver error scoping implemented
  with AI assistance.
