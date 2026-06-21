Security
--------

- CSRF tokens are now signed with **HMAC-SHA256 keyed by a server-side secret**
  and are **bound to a per-session id**, closing a forgery hole where tokens
  were signed with a bare ``SHA256`` digest against a static ``'no-session'``
  base. Previously any client could self-mint an accepted token
  (``token:SHA256("no-session:#{token}")``) and all sessionless tokens were
  mutually valid, defeating CSRF protection for any token issued before a
  session existed. ``Otto::Security::Config#generate_csrf_token`` now requires a
  non-empty session binding (raises ``ArgumentError`` otherwise) and
  ``#verify_csrf_token`` rejects blank bindings; both go through the keyed HMAC.
  The secret is read from ``ENV['OTTO_CSRF_SECRET']`` (or the new
  ``config.csrf_secret=`` accessor) and falls back to a random per-process
  secret with a one-time warning — set ``OTTO_CSRF_SECRET`` so tokens stay valid
  across workers and restarts. In **production** (``RACK_ENV=production``)
  enabling CSRF without a configured secret is a hard error rather than a silent
  fallback: it raises at config finalization (``deep_freeze!``) and at token
  generation, so a horizontally-scaled deployment fails loudly instead of
  serving non-persistent, cross-worker-invalid tokens. Non-production
  environments keep the zero-config generated-secret fallback. (otto#147)
- Class-name resolution for every dynamic-dispatch path now flows through a
  single validated ``Otto::Security::ConstantResolver.safe_const_get`` that
  enforces the class-name format and a forbidden-class blocklist (``Kernel``,
  ``Process``, ``IO``, ``File``, ``Object``, ...). Previously
  ``RouteHandlers::BaseHandler#safe_const_get`` (used by ``ClassMethodHandler`` /
  ``InstanceMethodHandler``) and the MCP dispatch in ``Otto::MCP::Registry`` and
  ``Otto::MCP::Server`` resolved handler class names with bare
  ``Object.const_get`` / ``const_get`` and no guards, bypassing the protections
  already present in ``Otto::Route``. The shared resolver also closes a blocklist
  gap present in the original ``Otto::Route`` check: a forbidden class reached
  through a namespace prefix (``"Object::Kernel"``) or via Ruby's trailing-segment
  constant inheritance (``"App::File"`` resolving to top-level ``::File``) is now
  rejected by an identity check on the *resolved* constant, while an app's own
  distinct class that merely shares a name is unaffected. (otto#147)
- MCP bearer-token authentication (``Otto::MCP::Auth::TokenAuth``) and API-key
  authentication (``Security::Authentication::Strategies::APIKeyStrategy``) now
  compare credentials in constant time with ``Rack::Utils.secure_compare``
  against every configured value, instead of ``Set#include?`` / ``Array#include?``
  which short-circuit and leak timing. The "no API keys configured accepts any
  key" semantics is preserved. (otto#147)

Fixed
-----

- The CSRF meta-tag injector now matches an opening ``<head>`` tag **with
  attributes** (e.g. ``<head class="x">``) using ``/<head(?:\s[^>]*)?>/i`` and
  preserves the original tag when injecting, instead of only matching a bare
  ``<head>``. The CSRF ``<meta>`` tag is no longer silently dropped on such
  documents (``<header>`` is still not matched). (otto#147)

Changed
-------

- ``RouteHandlers::BaseHandler`` now raises ``ArgumentError`` (not ``NameError``)
  when a handler's class name is malformed, forbidden, or not found, since it
  shares the validated resolver with ``Otto::Route``. Internal callers rescue
  ``StandardError`` and are unaffected; downstream code that specifically
  rescued ``NameError`` from handler resolution should rescue ``ArgumentError``
  (or ``StandardError``) instead. (otto#147)
- Removed the bare SQL-keyword substring blocklist
  (``union|select|insert|update|delete|...``) from
  ``ValidationMiddleware``'s ``SQL_INJECTION_PATTERNS``. It produced false
  positives on legitimate input (e.g. ``"updated_at"``, ``"selection"``) while
  remaining trivially bypassable, giving a false sense of protection. The
  remaining best-effort signatures stay as defense-in-depth; the real protection
  for SQL injection is parameterized queries / prepared statements at the
  data-access layer. (otto#147)

AI Assistance
-------------

- Static-analysis security findings (issue #147) triaged, fixed, and verified
  with AI assistance: parallel implementation across the CSRF, constant
  resolution, and constant-time-comparison work streams, followed by an
  adversarial finding-by-finding verification pass and a codebase sweep for the
  same anti-pattern classes.
