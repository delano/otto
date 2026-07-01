Added
-----

- Modern CSP Reporting API emission. Pass ``endpoint_url:`` to
  ``Otto#enable_csp_reporting!`` (or set ``config.csp_report_to_url=``) to emit a
  ``report-to`` directive and a ``Reporting-Endpoints`` response header alongside
  the legacy ``report-uri``, so browsers that have deprecated ``report-uri``
  still deliver violation reports. Off by default; policy output is
  byte-identical when unset.

AI Assistance
-------------

- ``report-to`` / ``Reporting-Endpoints`` emission implemented with AI
  assistance.
