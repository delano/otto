Fixed
-----

- CSP violation reports now reach the receiver when Otto is mounted under a
  sub-path. ``csp_report_uri`` is emitted verbatim as the ``report-uri``
  directive, which browsers resolve against the site root, but
  ``Otto::Security::CSP::ReportMiddleware`` compared it against the
  mount-relative ``PATH_INFO``, so no configured value worked in both places.
  The receiver now compares against ``SCRIPT_NAME`` + ``PATH_INFO``. Configure
  the site-absolute path, mount prefix included: ``/api/csp-report`` for an
  app under ``map '/api'``. A mount-relative value (``/csp-report``) no longer
  intercepts ``/api/csp-report``; the emitted header never sent browsers
  there. Unmounted apps are unaffected.

- The report receiver normalizes the request path and the configured path
  with ``Otto::Utils.normalize_path``, as the router does, so a trailing-slash
  or percent-encoded spelling of the report path is intercepted instead of
  falling through to a 404.
