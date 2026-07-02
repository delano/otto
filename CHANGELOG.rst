CHANGELOG.rst
=============

The format is based on `Keep a Changelog <https://keepachangelog.com/en/1.1.0/>`__, and this project adheres to `Semantic Versioning <https://semver.org/spec/v2.0.0.html>`__.

.. raw:: html

   <!--scriv-insert-here-->

.. _changelog-2.5.0:

2.5.0 — 2026-07-02
==================

Added
-----

- ``Otto::Security::CSP::Writer.apply(headers, nonce, config:, mode:,
  development_mode:)`` — the single structural apply core for nonce-based CSP
  emission. Writes are in-place and key-scoped (case-variant keys are corrected
  to Rack 3's lowercase in the caller's hash; a frozen headers hash fails loud).
  Returns a ``Result`` (``applied?``, ``policy``, ``skip_reason`` of
  ``:disabled`` / ``:blank_nonce`` / ``:non_html`` / ``:existing_csp``). Named
  modes ``:override`` (deliberate, replaces) and ``:backstop`` (passive,
  defers). (delano/otto#180)

- Framework-owned lazy nonce: ``Otto::Request#csp_nonce`` /
  ``Otto::Security::CSP.nonce(env)`` generate on first access and memoize into
  ``env['otto.nonce']`` (registered as ``Otto::EnvKeys::NONCE``), so views and
  the header read one value. Configurable env key via
  ``Otto::Security::Config#csp_nonce_key`` for apps with an existing convention.

- ``Otto::Security::CSP::EmitMiddleware`` and ``Otto#enable_csp_emission!`` — a
  passive backstop that emits a nonce CSP for HTML responses whose request
  consumed a nonce (emit-if-consumed default), never clobbering an existing
  policy. Optional ``eager:`` mode and a per-request ``development_mode:``
  callable.

- ``Otto::Response#apply_csp(nonce, mode: :override)`` — the one emission helper,
  routed through the apply core.

- ``Otto::Security::CSP::Policy`` — CSP policy building (directive sets,
  report-uri/report-to assembly) extracted from ``Otto::Security::Config`` into
  its own home beside the parser and middlewares; ``Config`` delegates with
  byte-identical output.

Deprecated
----------

- ``Otto::Response#send_csp_headers`` — use ``#apply_csp`` or
  ``#enable_csp_emission!``. Retained as a thin shim over the apply core (logs a
  one-time ``Otto.logger`` deprecation notice).

Fixed
-----

- ``#send_csp_headers`` no longer emits a broken ``script-src 'nonce-'`` for a
  blank/nil nonce (it skips) and no longer emits a CSP for non-HTML responses —
  both via the shared apply core. Its bare ``warn`` to stderr when overwriting an
  existing CSP is also gone: replacement is deliberate in ``:override`` mode, and
  the shim instead logs a one-time deprecation notice through ``Otto.logger``.

Security
--------

- Nonce-CSP emission now detects and normalizes CSP / Content-Type headers
  case-insensitively, so a canonical-/mixed-cased header from a downstream layer
  is recognized (and the CSP key rewritten to lowercase) rather than silently
  duplicated — de-duplicating the hand-rolled, case-sensitive guards adopters
  previously re-implemented at each raw-tuple boundary. (delano/otto#180)

AI Assistance
-------------

- The nonce-CSP emission redesign — the ``Writer`` apply core, the
  framework-owned lazy nonce, the ``EmitMiddleware`` backstop, and the
  ``Policy`` extraction — was designed and implemented with AI assistance.
  (delano/otto#180)

.. _changelog-2.4.0:

2.4.0 — 2026-07-01
==================

Added
-----

- ``Otto#enable_csp_reporting!(report_uri, endpoint_url: nil, &block)`` —
  turnkey CSP violation reporting. Emits a ``report-uri`` directive and, with
  ``endpoint_url:``, a ``report-to`` directive plus ``Reporting-Endpoints``
  header. Parses legacy ``application/csp-report`` and Reporting API
  ``application/reports+json`` payloads into ``Otto::Security::CSP::Report``
  and invokes the callback per violation. Opt-in. (delano/otto#174)

- ``MiddlewareStack`` ``:outermost`` position, for middleware that must run
  ahead of all others regardless of registration order.

- ``Otto::CaddyTLS``: an opt-in Caddy on-demand TLS permission endpoint,
  enabled with ``otto.enable_caddy_tls! { |domain| ... }``. (delano/otto#175)

Fixed
-----

- ``IPPrivacyMiddleware`` no longer writes ``nil`` into CGI-style Rack env
  keys (e.g. ``HTTP_REFERER``, ``HTTP_USER_AGENT``, ``REMOTE_ADDR``) when
  redacting request data, which violated the Rack SPEC and tripped
  ``Rack::Lint``. Empty anonymized values now delete the key instead of
  setting it to ``nil``, and a request with no resolvable client IP no
  longer gets a ``nil`` ``REMOTE_ADDR``. (delano/otto#167)

- ``Otto::Security::CSP::ReportMiddleware`` no longer turns a downstream
  error on a non-report request into an empty ``204``.

Security
--------

- The ``Otto::CaddyTLS`` permission endpoint is loopback-only by default and
  fails closed. (delano/otto#175)

- Security middleware registered through the ``otto.security.*``
  Configurator after ``Otto.new`` now actually runs on the request chain —
  previously CSRF, request validation, rate limiting, and CSP reporting
  silently went unenforced.

AI Assistance
-------------

- CSP violation reporting (``report-uri`` / ``report-to``), the
  ``:outermost`` middleware position, and the Configurator
  middleware-registration fix were designed and implemented with AI
  assistance.

- ``Otto::CaddyTLS`` designed, implemented, and reviewed with AI assistance.

- The Rack SPEC ``nil``-into-CGI-key fix — including the sibling
  ``REMOTE_ADDR`` masking bug and ``Rack::Lint`` test coverage — diagnosed
  and fixed with AI assistance.

.. _changelog-2.3.1:

2.3.1 — 2026-06-22
==================

Added
-----

- Depth mode (``Otto::Security::Config#trusted_proxy_depth``) can now count hops
  from a configurable forwarded header, via a new ``#trusted_proxy_header``
  accessor: ``X-Forwarded-For`` (default), ``Forwarded`` (RFC 7239), or ``Both``
  (``Forwarded`` when it carries a ``for=``, otherwise ``X-Forwarded-For``).
  Settable through ``Otto::Security::Configurator#configure`` and the
  ``trusted_proxy_header`` option of ``Otto.new`` / ``configure_security``; an
  unrecognized value raises ``ArgumentError`` at assignment. This reaches parity
  with OneTimeSecret's ``site.network.trusted_proxy.header``. (delano/otto#150,
  onetimesecret#3436)

AI Assistance
-------------

- RFC 7239 ``Forwarded`` / ``Both`` depth-header support designed and implemented
  with AI pair programming, with per-header, quoted-IPv6, and ``Both``-precedence
  test coverage.

.. _changelog-2.3.0:

2.3.0 — 2026-06-21
==================

Added
-----

- Count-based trusted-proxy resolution ("trust the last N hops"), the Express
  ``trust proxy = N`` primitive, via a new
  ``Otto::Security::Config#trusted_proxy_depth`` accessor (Integer, default
  ``nil``). ``nil`` / ``0`` keeps the existing CIDR-walk; ``>= 1`` enables depth
  mode. This is the sound model for non-enumerable proxy tiers (Fly, cloud load
  balancers, dynamic reverse proxies) whose addresses cannot be listed as CIDRs.
  Resolution flows through the shared ``Otto::Utils.resolve_client_ip``, so the
  canonical ``env['otto.client_ip']`` (masking, idempotency, "read everywhere")
  and the standalone ``Request#client_ipaddress`` fallback both honor depth with
  no further wiring. Settable through ``Otto::Security::Configurator#configure``
  (``trusted_proxy_depth:``) and the ``trusted_proxy_depth`` option of
  ``configure_security``. Depth resolves the client *IP* only; it is decoupled
  from proxy proto-trust — ``env['otto.via_trusted_proxy']`` (and therefore
  ``Otto::Request#secure?`` honoring ``X-Forwarded-Proto`` / ``X-Scheme``) remains
  the trusted-proxy *identity* check and is never derived from hop depth,
  matching the downstream OneTimeSecret behavior. (onetimesecret#3436,
  onetimesecret#3116)

Changed
-------

- ``Otto::Security::Config#trusted_proxy?`` now matches string entries with
  proper ``IPAddr`` CIDR containment for both IPv4 and IPv6, replacing the
  previous ``==`` / ``start_with?`` text matching. Bare hosts (e.g.
  ``192.168.1.1``) match only exactly, and CIDR ranges (e.g. ``10.0.0.0/8``)
  now actually match contained addresses. Non-IP entries (e.g. ``172.16.``)
  still fall back to the legacy prefix match, and ``Regexp`` entries are
  unchanged. This is a behavior change: addresses that were previously
  matched only because they shared a textual prefix are no longer treated as
  trusted. (otto#58, onetimesecret#3436)
- ``IPPrivacyMiddleware`` now resolves the client IP once into a canonical
  ``env['otto.client_ip']`` ("resolve once, read everywhere") and is
  idempotent: a second pass (e.g. when the middleware is mounted both at the
  app and router levels) yields instead of re-resolving and double-masking.
- ``Otto::Request#ip`` and ``#client_ipaddress`` now prefer
  ``env['otto.client_ip']`` when present, falling back to Rack's native
  resolution when the middleware has not run. Downstream code no longer
  depends on ``REMOTE_ADDR`` / ``X-Forwarded-For`` rewriting being
  load-bearing.
- ``Otto::Request#secure?`` now authorizes ``X-Forwarded-Proto`` /
  ``X-Scheme`` from a canonical, leak-free ``env['otto.via_trusted_proxy']``
  flag recorded by ``IPPrivacyMiddleware`` before masking, instead of
  re-deriving trust from the (now masked) ``REMOTE_ADDR``. It falls back to
  the previous behavior when the middleware has not run.
- ``add_trusted_proxy`` now logs a warning when given a string that is not a
  valid IP or CIDR (e.g. ``'172.16.'``), since such entries use legacy
  string-prefix matching; prefer a CIDR range.
- IP validation and port-stripping were consolidated into
  ``Otto::Utils.normalize_ip`` / ``strip_ip_port`` (previously duplicated in
  ``IPPrivacyMiddleware`` and ``Otto::Request``).
- Trusted-proxy string entries are now parsed to ``IPAddr`` once at
  registration (in ``add_trusted_proxy``) and cached, so ``trusted_proxy?``
  no longer re-parses each entry on every request.
- Client-IP resolution from forwarded headers is now a single shared
  ``Otto::Utils.resolve_client_ip`` used by both ``IPPrivacyMiddleware``
  ("resolve once") and ``Otto::Request#client_ipaddress`` (its no-middleware
  fallback), so the two paths can no longer disagree on which headers to trust
  or how to walk a proxy chain. The standalone ``Request`` fallback now walks
  the forwarded chain skipping trusted proxies (matching the middleware) and
  consults ``X-Client-IP`` instead of the legacy ``Client-IP`` header.

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

Fixed
-----

- IPv6 addresses are no longer truncated during proxy resolution.
  ``validate_ip_address`` previously did ``ip.split(':').first``, collapsing
  an IPv6 address to its first hextet; it now uses ``IPAddr`` validation with
  IPv6-safe port stripping (bracketed ``[2001:db8::1]:443`` and IPv4
  ``host:port``). IPv6 clients behind trusted proxies now resolve and mask
  correctly. (onetimesecret#3436)
- ``Otto::Request#redacted_fingerprint``, ``#geo_country``, ``#hashed_ip``
  and ``#masked_ip`` (plus ``NoAuthStrategy`` metadata and
  ``LoggingHelpers`` country) read the canonical ``otto.privacy.*`` env keys
  the middleware actually writes; they previously read un-namespaced keys
  that were never set and so always returned ``nil``.
- ``Otto::Request#private_ip?`` (and therefore ``#local_or_private_ip?`` /
  ``#local?``) is now IPv4- **and** IPv6-aware via ``Otto::Utils.private_ip?``.
  It recognizes IPv6 loopback (``::1``), unique-local (``fc00::/7``),
  link-local (``fe80::/10``), multicast and unspecified addresses; the previous
  IPv4-only regex silently classified every IPv6 address as public.
- Anonymous and auth-failure metadata (``NoAuthStrategy``,
  ``RouteAuthWrapper``) and ``LoggingHelpers.request_context`` now record the
  canonical ``otto.client_ip`` (falling back to ``REMOTE_ADDR``), so the real
  client — not the connecting proxy — is logged when IP privacy is disabled
  behind a trusted proxy.

- The CSRF ``<meta>`` tag is now injected into ``<head>`` tags that carry
  attributes, not only a bare ``<head>``. (otto#147)

Security
--------

- Trusted-proxy matching is now correct CIDR containment rather than text
  prefix matching, removing both false positives (e.g. ``192.168.1.100``
  matching the host ``192.168.1.1``) and false negatives (CIDR ranges that
  never matched). ``secure?`` no longer silently fails to trust
  ``X-Forwarded-Proto`` behind a TLS-terminating trusted proxy when IP
  privacy is enabled. (onetimesecret#3436)

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

- Depth resolution trusts exactly N hops counted from the right of
  ``X-Forwarded-For`` plus ``REMOTE_ADDR``, so a forged leftmost forwarded entry
  is never reached. Positions are counted raw (never dropped) so junk padding
  cannot shift the index, and only the selected entry is validated. A chain
  shorter than ``N + 1`` (a request that may have bypassed the proxy tier) or an
  invalid target entry falls back to ``REMOTE_ADDR`` rather than a spoofable
  forwarded value. Depth mode is XFF-only (single-value ``X-Real-IP`` /
  ``X-Client-IP`` cannot express a hop chain) and **assumes origin lockdown** —
  the app must be unreachable except through the proxy tier. CIDR-walk and depth
  are mutually exclusive, and ``trusted_proxy_depth`` must be a non-negative
  Integer or ``nil``; both are validated immediately at configuration time (with
  a freeze-time backstop), so an invalid or contradictory setup fails fast.

Documentation
-------------

- Extended ``docs/migrating/v2.3.0.md`` with a count-based depth section covering
  when to use depth vs CIDR-walk, the origin-lockdown prerequisite, configuration
  examples, Express parity, and the XFF-only / short-chain / mutual-exclusivity
  semantics.

AI Assistance
-------------

- Issue #147 findings triaged, fixed, and verified with AI assistance, including
  an adversarial review that surfaced the namespace-prefix blocklist bypass.

- Trusted-proxy depth design review, threat-model analysis (origin-lockdown
  trade vs CIDR enumerability, raw-position counting to defeat XFF padding),
  implementation and test coverage developed with AI pair programming.

.. _changelog-2.2.0:

2.2.0 — 2026-06-09
==================

Added
-----

- Added ``AuthorizationFailure`` result type for auth strategies to signal 403 Forbidden distinct from 401 Unauthorized. Strategies that perform combined authentication and authorization in one pass can now return ``authorization_failure(reason)`` when a valid credential is denied a permission, allowing ``RouteAuthWrapper`` to map the result to a proper 403 response rather than collapsing it to 401.
- Added ``#authorization_failure`` helper to ``AuthStrategy`` base class for consistent error signaling across strategy implementations.
- Extracted ``#strategy_auth_method`` private helper to handle anonymous strategy classes (common in tests) that have a nil ``#name``.

.. _changelog-2.1.0:

2.1.0 — 2026-05-27
==================

- Add ``Otto#on_route_matched`` lifecycle hook. Callbacks fire after a
  route matches but before the handler dispatches, with signature
  ``(env, route_definition)``. Mirrors ``on_request_complete`` for
  registration and freezing, but exceptions raised from a callback
  propagate through ``handle_error`` rather than being swallowed, so
  consumers can route custom error classes through
  ``register_error_handler`` for short-circuit gating. Skipped for
  static file routes and the 404 fallback; fires on both literal and
  dynamic matches. Per-instance state, zero overhead when no callbacks
  are registered. (#129)

- Add ``Otto#register_handler_wrapper`` API for per-request handler
  composition. Registers factory blocks composed around each route
  handler at request time; wrappers nest outermost-first in
  registration order, with ``RouteAuthWrapper`` preserved as the
  innermost wrapper so consumers see ``env['otto.strategy_result']``.
  ``freeze_configuration!`` now exercises every registered wrapper
  against every loaded route, surfacing ``TypeError`` and factory bugs
  at boot rather than on the first matching request. (#130)

.. _changelog-2.0.2:

2.0.2 — 2026-04-15
==================

- Load failure under facets 3.2.0. ``Otto::Security::ValidationHelpers`` no
  longer requires ``facets/file``, whose aggregator in 3.2.0 does
  ``require_relative 'file/write.rb'`` against a file deleted in the same
  release. The one function Otto borrowed from facets — ``File.sanitize`` —
  is now inlined as a private method on the helper module (with credit in
  the source comment), and the ``facets`` runtime dependency is removed
  from the gemspec entirely. Applications depending on facets directly are
  unaffected.

- CI now runs the RSpec suite twice for each Ruby in the matrix: once
  against the committed ``Gemfile.lock`` and once with the lockfile removed
  so Bundler resolves fresh inside the gemspec's pessimistic constraints.
  The unlocked cells catch upstream releases that satisfy ``~> X.Y`` but
  break Otto at load time.

.. _changelog-2.0.1:

2.0.1 — 2026-04-15
==================

- Allow running with Ruby 4
- Update gems rack, ruby-lsp, rspec, rubocop, loofah, rack-test

.. _changelog-2.0.0:

2.0.0 — 2026-03-14
==================

Added
-----

- Optional ``fallback_locale`` configuration for ``Otto::Locale::Middleware`` and ``Locale::Config``, enabling custom locale fallback chains between exact region match and primary code resolution

Fixed
-----

- Locale middleware now tries exact region match (``fr-FR`` → ``fr_FR``) before falling back to primary language code, fixing locale resolution for region-qualified ``available_locales`` entries (#117)

.. _changelog-2.0.0.pre10:

2.0.0.pre10 — 2025-12-09
========================

Added
-----

- ``Otto::Request`` and ``Otto::Response`` classes extending Rack equivalents
- ``register_request_helpers`` and ``register_response_helpers`` for application-specific helpers
- Helper modules included at class level (not per-request extension)

Changed
-------

- Moved ``lib/otto/helpers/request.rb`` → ``lib/otto/request.rb``
- Moved ``lib/otto/helpers/response.rb`` → ``lib/otto/response.rb``
- All internal code now uses ``Otto::Request``/``Otto::Response`` instead of ``Rack::Request``/``Rack::Response``

.. _changelog-2.0.0.pre9:

2.0.0.pre9 — 2025-12-06
=======================

Added
-----

- Base HTTP error classes (``Otto::NotFoundError``, ``Otto::BadRequestError``, ``Otto::ForbiddenError``, ``Otto::UnauthorizedError``, ``Otto::PayloadTooLargeError``) that implementing projects can subclass for consistent error handling
- Auto-registration of all framework error classes during ``Otto#initialize`` - framework errors now automatically return correct HTTP status codes without manual registration

Changed
-------

- Framework error classes now inherit from new base classes: ``Otto::Security::AuthorizationError`` < ``Otto::ForbiddenError``, ``Otto::Security::CSRFError`` < ``Otto::ForbiddenError``, ``Otto::Security::RequestTooLargeError`` < ``Otto::PayloadTooLargeError``, ``Otto::Security::ValidationError`` < ``Otto::BadRequestError``, ``Otto::MCP::ValidationError`` < ``Otto::BadRequestError``
- ``Otto::Security::RequestTooLargeError`` now returns HTTP 413 (Payload Too Large) instead of 500, semantically correct per RFC 7231

- Consolidated route handler implementation using Template Method pattern, reducing duplication by ~120 lines while improving maintainability

Fixed
-----

- Error handlers now respect route's ``response=json`` parameter for content
  negotiation, ensuring API routes always return JSON error responses regardless
  of the Accept header.

- Rate limiters now respect route ``response=json`` declarations when returning
  throttled responses, matching the error handler fix for consistent content
  negotiation across all error paths.

- ClassMethodHandler direct testing context now respects route ``response_type``
  when generating error responses.

- Unified error handling across ClassMethodHandler and InstanceMethodHandler to consistently support JSON content negotiation

AI Assistance
-------------

- Implementation design and architecture developed with AI pair programming
- Comprehensive test coverage (31 new base class tests, 12 auto-registration tests) developed with AI assistance
- Error class hierarchy and inheritance patterns refined through AI-guided architectural discussion

.. _changelog-2.0.0.pre8:

2.0.0.pre8 — 2025-11-27
=======================

Fixed
-----

- Routes declaring ``response=json`` now return 401 JSON errors instead of 302 redirects when authentication fails, regardless of Accept header. The route's explicit configuration takes precedence over content negotiation.

.. _changelog-2.0.0.pre7:

2.0.0.pre7 — 2025-11-24
=======================

Added
-----

- Error handler registration system for expected business logic errors via ``otto.register_error_handler(ErrorClass, status:, log_level:)``. Supports custom response handlers via blocks.

Changed
-------

- Backtrace logging now always logs at ERROR level with sanitized file paths (was DEBUG level with full paths)
- Increased backtrace limit from 10 to 20 lines for better debugging context
- Improved gem path formatting in backtraces (e.g., ``[GEM] rack/lib/rack.rb:20``)

Fixed
-----

- Fixed path sanitization for bundler git-based gems and multi-hyphenated gem names

Documentation
-------------

- Documented security guarantees and sanitization rules
- Added examples showing before/after path transformations

AI Assistance
-------------

- Implemented error handler registration architecture with comprehensive test coverage (17 test cases) using sequential thinking to work through security implications and design decisions. AI assisted with path sanitization strategy, error classification patterns, and ensuring backward compatibility with existing error handling.

.. _changelog-2.0.0.pre6:

2.0.0.pre6
==========

Changed
-------

- **BREAKING**: ``Otto.on_request_complete`` is now an instance method instead of a class method. This fixes duplicate callback invocations in multi-app architectures (e.g., Rack::URLMap with multiple Otto instances). Each Otto instance now maintains its own isolated set of callbacks that only fire for requests processed by that specific instance.

  **Migration**: Change ``Otto.on_request_complete { |req, res, dur| ... }`` to ``otto.on_request_complete { |req, res, dur| ... }``

- **Logging**: Eliminated duplicate error logging in route handlers. Previously, errors produced two log lines ("Handler execution failed" + "Unhandled error in request"). Now produces a single comprehensive error log with all context (handler, duration, error_id). Lambda handlers now use centralized error handling for consistency. #86

Fixed
-----

- Fixed issue #84 where ``on_request_complete`` callbacks would fire N times per request in multi-app architectures, causing duplicate logging and metrics
- Fixed ``Otto.structured_log`` to respect ``Otto.debug`` flag - debug logs are now properly skipped when ``Otto.debug = false``

AI Assistance
-------------

- This enhancement was developed with assistance from Claude Code (Opus 4.1)

.. _changelog-2.0.0.pre5:

2.0.0.pre5 — 2025-10-21
=======================

Added
-----

- Added ``Otto::LoggingHelpers.log_timed_operation`` for automatic timing and error handling of operations
- Added ``Otto::LoggingHelpers.log_backtrace`` for consistent backtrace logging with correlation fields
- Added microsecond-precision timing to configuration freeze process
- Added unique error ID generation for nested error handler failures (links via ``original_error_id``)

Changed
-------

- Timing precision standardization: All timing calculations now use microsecond precision instead of milliseconds. This affects authentication duration tracking and request lifecycle timing. Duration values are now reported in microseconds as integers (e.g., ``15200`` instead of ``15.2``).
- Request completion hooks API improvement: ``Otto.on_request_complete`` callbacks now receive a ``Rack::Response`` object instead of the raw ``[status, headers, body]`` tuple. This provides a more developer-friendly API consistent with ``Rack::Request``, allowing clean access via ``res.status``, ``res.headers``, and ``res.body`` instead of array indexing.
- All timing now uses microseconds (``Otto::Utils.now_in_μs``) for consistency
- Configuration freeze process now logs detailed timing metrics

Documentation
-------------

- Added example application demonstrating three new logging patterns (``examples/logging_improvements.rb``)
- Documented base context pattern for downstream projects to inject custom correlation fields
- Added output examples for both structured and standard loggers

AI Assistance
-------------

- This enhancement was developed with assistance from Claude Code (Opus 4.1)

   .. _changelog-2.0.0.pre4:


2.0.0.pre4 — 2025-10-20
=======================
Changed
-------
- Authentication moved from middleware to RouteAuthWrapper at handler level (executes after routing)
- RouteAuthWrapper now wraps all routes and provides session persistence, security headers, strategy caching, and pattern matching (exact, prefix, fallback)
- env['otto.strategy_result'] now guaranteed present on all routes (authenticated or anonymous)
- Renamed MiddlewareStack#build_app to #wrap (reflects per-request wrapping vs one-time initialization)

Removed
-------
- AuthenticationMiddleware (executed before routing)
- enable_authentication! (RouteAuthWrapper handles auth automatically)
- Defensive nil fallback from LogicClassHandler (no longer needed)

Fixed
-----
- Session persistence: env['rack.session'] now references same object as strategy_result.session
- Security headers included on all auth failure responses (401/302)
- Anonymous routes now receive StrategyResult with IP metadata

Documentation
-------------
- Updated CLAUDE.md with RouteAuthWrapper architecture
- Updated env_keys.rb to document strategy_result guarantee
- Added tests for anonymous route handling


.. _changelog-2.0.0.pre2:

2.0.0.pre2 — 2025-10-11
=======================

Added
-----

- Added `StrategyResult` class with improved user model compatibility and cleaner API
- Helper methods ``authenticated?``, ``has_role?``, ``has_permission?``, ``user_name``, ``session_id`` for cleaner Logic class implementation
- Added JSON request body parsing support in Logic class handlers
- Added new modular directory structure under ``lib/otto/security/``
- Added backward compatibility aliases to maintain existing API compatibility
- Added proper namespacing for authentication components and middleware classes

Changed
-------

- **BREAKING**: Logic class constructor signature changed from ``initialize(session, user, params, locale)`` to ``initialize(context, params, locale)``
- Logic classes now receive an immutable context object instead of separate session/user parameters
- LogicClassHandler simplified to single arity pattern, removing backward compatibility code
- Authentication middleware now creates `StrategyResult` instances for all requests
- Replaced `RequestContext` with `StrategyResult` class for better authentication handling
- Simplified authentication strategy API to return `StrategyResult` or `nil` for success/failure
- Enhanced route handlers to support JSON request body parsing
- Updated authentication middleware to use `StrategyResult` throughout
- Reorganized Otto security module structure for better maintainability and separation of concerns
- Moved authentication strategies to ``Otto::Security::Authentication::Strategies`` namespace
- Moved security middleware to ``Otto::Security::Middleware`` namespace
- Moved ``StrategyResult`` and ``FailureResult`` to ``Otto::Security::Authentication`` namespace

Removed
-------

- Removed `RequestContext` class (which was introduced and then replaced by `StrategyResult` during this development cycle)
- Removed `AuthResult` class from authentication system
- Removed `ConcurrentCacheStore` example class for an ActiveSupport::Cache::MemoryStore-compatible interface with Rack::Attack
- Removed OpenStruct dependency across the framework

Documentation
-------------

- Updated migration guide with comprehensive examples for the new context object and step-by-step conversion instructions
- Updated Logic class examples in advanced_routes and authentication_strategies to demonstrate new pattern
- Enhanced documentation with API reference and helper method examples for the new context object

AI Assistance
-------------

- AI-assisted architectural design for RequestContext Data class and security module reorganization
- Comprehensive migration of Logic classes and documentation with AI guidance for consistency
- Automated test validation and intelligent file organization following Ruby conventions


.. _changelog-2.0.0-pre1:

2.0.0-pre1 — 2025-09-10
=======================

Added
-----

- Comprehensive test coverage for error handling methods (handle_error, secure_error_response,
json_error_response)
- Test coverage for private configuration methods (configure_locale, configure_security,
configure_authentication, configure_mcp)
- Expanded MCP functionality test coverage including route parsing and server initialization
- Security header validation in all error responses
- Content negotiation testing for JSON vs plain text error responses
- Development vs production mode error handling verification

- ``Otto::Security::Configurator`` class for consolidated security configuration
- ``Otto::Core::MiddlewareStack`` class for enhanced middleware management
- Unified ``security.configure()`` method for streamlined security setup
- Middleware introspection capabilities via ``middleware_list`` and ``middleware_details`` methods

Changed
-------

- **BREAKING**: Direct middleware_stack manipulation no longer supported. Use ``otto.use()`` instead
of ``otto.middleware_stack <<``. See `migration guide <docs/migrating/v2.0.0-pre1.md>`__ for upgrade
path.

- Refactored main Otto class from 767 lines to 348 lines using composition pattern (#29)
- Modernized initialization method with helper functions while maintaining backward compatibility
- Applied Ruby 3.2+ features including pattern matching and anonymous block forwarding
- Improved method organization and separation of concerns

- Refactored security configuration methods to use new ``Otto::Security::Configurator`` facade
- Enhanced middleware stack management with better registration and execution interfaces
- Improved separation of concerns between security configuration and middleware handling

- Unified middleware stack implementation for improved performance and consistency
- Optimized middleware lookup and registration with O(1) Set-based tracking
- Memoized middleware list to reduce array creation overhead
- Improved middleware registration to handle varied argument scenarios

Documentation
-------------

- Added changelog management system with Scriv configuration
- Created comprehensive changelog process documentation

AI Assistance
-------------

- Comprehensive test suite development covering 76 new test cases across 3 test files
- Error handling analysis and edge case identification
- Configuration method testing strategy development
- MCP functionality testing with proper mocking and stubbing techniques
- Test quality assurance ensuring all 460 examples pass with 0 failures

- Extracted core Otto class functionality into 5 focused modules (Router, FileSafety, Configuration,
ErrorHandler, UriGenerator) using composition pattern for improved maintainability while preserving
complete API backward compatibility (#28)

- Comprehensive refactoring implementation developed with AI assistance
- Systematic approach to maintaining backward compatibility during modernization
- Full test suite validation ensuring zero breaking changes across 460 test cases

- Comprehensive refactoring of middleware stack management
- Performance optimization and code quality improvements
- Developed detailed migration guide for smooth transition
