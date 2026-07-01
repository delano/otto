Security
--------

- Security middleware added through the ``otto.security.*`` Configurator after
  ``Otto.new`` now runs on the request chain. It previously registered without
  taking effect, leaving CSRF, request validation, rate limiting, and CSP
  reporting unenforced.

Fixed
-----

- ``Otto::Security::CSP::ReportMiddleware`` no longer turns a downstream error on
  a non-report request into an empty ``204``.

AI Assistance
-------------

- Middleware-rebuild fix and report-receiver error scoping implemented with AI
  assistance.
