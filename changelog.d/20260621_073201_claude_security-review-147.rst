Security
--------

- CSRF tokens are now signed with HMAC-SHA256 keyed by a server-side secret and
  bound to the session id, so they can no longer be self-minted or replayed
  across sessions. Set the secret via ``OTTO_CSRF_SECRET`` or
  ``Otto::Security::Config#csrf_secret=``; enabling CSRF in production without
  one now raises instead of silently using a per-process secret. (otto#147)
- All route/handler class-name resolution goes through
  ``Otto::Security::ConstantResolver``, extending the existing format check and
  forbidden-class blocklist to ``RouteHandlers::BaseHandler`` and the MCP
  registry/server (previously unguarded). Forbidden classes reached via a
  namespace prefix or constant inheritance (e.g. ``Object::Kernel``) are now
  rejected as well. (otto#147)
- MCP bearer tokens and API keys are compared in constant time. (otto#147)

Fixed
-----

- The CSRF ``<meta>`` tag is now injected into ``<head>`` tags that carry
  attributes, not only a bare ``<head>``. (otto#147)

Changed
-------

- ``RouteHandlers::BaseHandler`` raises ``ArgumentError`` (was ``NameError``)
  for an unresolvable handler class name. (otto#147)
- ``Otto.logger`` never returns ``nil`` (lazy ``$stdout`` default); assign
  ``Otto.logger=`` to override or silence. (otto#147)

Removed
-------

- SQL-injection pattern matching from input validation
  (``ValidationMiddleware::SQL_INJECTION_PATTERNS`` and related checks). It
  produced false positives and was trivially bypassable; defend against SQL
  injection with parameterized queries at the data-access layer. (otto#147)

AI Assistance
-------------

- Issue #147 findings triaged, fixed, and verified with AI assistance, including
  an adversarial review that surfaced the namespace-prefix blocklist bypass.
