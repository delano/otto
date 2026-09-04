CHANGELOG.rst
=============

The format is based on `Keep a Changelog <https://keepachangelog.com/en/1.1.0/>`__, and this project adheres to `Semantic Versioning <https://semver.org/spec/v2.0.0.html>`__.

.. raw:: html

   <!--scriv-insert-here-->

.. _changelog-2.9.0:

2.9.0 — 2026-08-18
==================

Added
-----

- Add opt-in request-scoped CSP directive extras for sources that are known
  only while handling a request. Enable the feature at boot with
  ``security_config.enable_csp_request_extras!``, then add approved source
  origins by directive through ``env['otto.csp.extra_directives']``. This
  supports cases such as adding a tenant's SSO provider to ``form-action``.
  Disabled by default. (#243)

Fixed
-----

- Prevent request-scoped CSP extras from invalidating valueless directives,
  including ``upgrade-insecure-requests`` and ``block-all-mixed-content``.
  Unsupported extras are ignored and logged; valid extras for other
  directives continue to apply. (#243)

Security
--------

- Validate request-scoped CSP extras before adding them to a response policy.
  Extras can only add valid HTTP(S) origins to compatible directives already
  present in the configured policy; script and default source directives are
  excluded. Invalid or unsupported entries are ignored and logged without
  affecting the remaining policy. (#243)

- Reject request-scoped CSP extras for valueless directives during input
  validation, with equivalent protection for direct CSP policy generation.
  (#243)

.. _changelog-2.8.1:

2.8.1 — 2026-08-16
==================

Added
-----

- Opt-in ASN resolution: ``req.asn`` / ``env['otto.privacy.asn']`` resolves
  the client's network operator (``'AS15169'``) from a local MaxMind-format
  database configured via ``configure_ip_privacy(asn: true, asn_db_path:
  ...)`` (or a bring-your-own ``asn_db_reader``). Database-only — no header
  tier exists, so the ``geo_header``/``trusted_proxy_depth`` conflict
  machinery does not apply — and the lookup uses the already-masked IP, which
  is safe because IPv4 BGP routes are not announced longer than /24. Off by
  default: ``nil`` when disabled, ``'**'`` when enabled but unresolved.

- Opt-in anonymizer classification: ``req.anonymizer`` /
  ``env['otto.privacy.anonymizer']`` labels the client address as ``'tor'``,
  ``'proxy'``, ``'vpn'``, ``'residential_proxy'``, ``'hosting'``,
  ``'anonymous'``, ``'none'`` (consulted, not listed), or ``'**'`` (no
  answer), from a local anonymous-IP database
  (``configure_ip_privacy(anonymizer: true, anonymizer_db_path: ...)``).
  This is the one database lookup performed on the UNMASKED address:
  anonymizer data lists individual egress nodes at or near /32, so a masked
  lookup would answer for the node's neighbours — flagging innocent
  addresses and missing actual exit nodes. Only the label ever leaves the
  resolver, the same containment contract as ``hash_ip`` and
  ``env['otto.ip_match']``. Off by default.

Documentation
-------------

- New ``docs/enrichment.md`` covering both signals, including the corrected
  dataset guidance: ``geo-whois-asn-country`` is a country database (the
  ``asn`` in its name describes its data *sources*, not its record
  contents); deployments wanting ASN data need a separate ASN file, e.g.
  sapics ``origin-asn`` (PDDL, rebuilt daily) — verified against the
  published file, whose records carry a flat ``autonomous_system_number``.

.. _changelog-2.8.0:

2.8.0 — 2026-08-07
==================

Changed
-------

- ``env['otto.via_trusted_proxy']`` is now tri-state: written only when proxy
  trust is configured (CIDR matchers or ``trusted_proxy_depth``). A present
  key is authoritative in both directions; an absent key means
  "unconfigured". Consumers reading the raw env key should presence-check
  (``env.key?``) rather than compare ``== true``. (#228)

- Configuring an ip-privacy ``geo_header`` together with
  ``trusted_proxy_depth`` now raises ``ArgumentError`` at configuration time:
  geo headers are only honored for CIDR-verified proxies, so under depth mode
  the header could never be consulted. Database-backed geo (``geo_db_path`` /
  ``geo_db_reader``) remains fully supported under depth. (#228)

Fixed
-----

- Depth mode now records a peer-trust verdict in
  ``env['otto.via_trusted_proxy']`` (previously always ``false``, leaving
  downstream middleware with no trust signal);
  ``Otto::Request#forwarded_by_trusted_proxy?`` mirrors the grant on its
  no-middleware fallback path. (#226)

Documentation
-------------

- Corrected the v2.3.0 migration guide's depth-porting guidance: map depth
  values directly, not ``+1`` — otto's chain index already accounts for the
  appended ``REMOTE_ADDR``. (#227, #228)

.. _changelog-2.7.0:

2.7.0 — 2026-08-03
==================

Added
-----

- Configurable geo-country resolution. ``configure_ip_privacy`` now accepts
  ``geo_header:`` — a trusted, app-configured request header checked *before*
  the built-in CDN headers (e.g. ``geo_header: 'X-Client-Country'``);
  ``geo_db_path:`` — a MaxMind-format ``.mmdb`` country database giving an
  offline IP->country fallback (needs the optional ``maxmind-db`` gem); and
  ``geo_db_reader:`` — bring your own reader (any object responding to
  ``#get``). A bad ``geo_db_path`` fails at boot, not per-request. (#206)

- ``X-Vercel-IP-Country`` is now recognized among the built-in CDN/provider
  geo headers. (#206)

- Named privacy profiles: ``configure_ip_privacy(profile: :anonymous | :masked
  | :audit)`` (also accepted by ``Otto::Privacy::Config.new``) — a validated
  preset over the existing knobs. ``:masked`` is the default posture (public
  IPs masked, private exempt), ``:anonymous`` masks every IP including
  private/localhost, and ``:audit`` disables IP privacy for
  private/compliance environments (retention responsibility transfers to the
  operator). ``Config#profile`` derives the label from live knob state, so it
  cannot go stale. Unknown names raise ``ArgumentError``. (#218)

- ``env['otto.ip_match']``: a verdict-only CIDR membership check over the
  resolved, UNMASKED client IP, installed by ``IPPrivacyMiddleware`` under
  every profile. Call it with an array of CIDR strings (or ``IPAddr``
  objects) and get ``true``/``false`` back, so downstream access control
  (e.g. a per-tenant allowlist) can match at full /32–/128 precision while
  ``otto.client_ip``, ``REMOTE_ADDR``, logs, and fingerprints stay masked —
  only the closure lands in env, never the address. Returns ``false`` when no
  client IP resolves (fail-closed); invalid CIDR entries raise
  ``IPAddr::InvalidAddressError``. (#218)

- ``Otto::Utils.ip_in_cidrs?(ip, cidrs)``: the general-purpose CIDR-set
  matcher behind ``otto.ip_match``, sharing the trusted-proxy matcher's
  semantics (port stripping, ``IPAddr#native`` folding, family-aware
  skipping). Runtime ``ip`` fails closed; invalid ``cidrs`` entries raise.
  Accepts pre-parsed ``IPAddr`` entries for hot paths. (#218)

- ``MiddlewareStack#execution_order`` returns middleware classes in the order
  they actually run (outermost first), resolving pin tiers — unlike
  ``#middleware_list``, which reports registration order. (#219)

- ``add_with_position`` accepts ``position: :innermost`` as a clearer synonym
  for ``:first``, and a new ``position: :entrypoint`` tier that pins middleware
  outside even ``:outermost`` entries. (#219)

- ``AuthFailure`` now carries a ``terminal`` flag (``terminal?`` predicate),
  and ``AuthStrategy#failure`` accepts ``terminal: true`` — meaning "credentials
  were presented, examined, and rejected; do not consult further strategies."
  ``RouteAuthWrapper`` halts the chain and renders that failure's 401
  regardless of strategy order, so mixed chains (``auth=basicauth,noauth``)
  fail closed on invalid credentials instead of proceeding as anonymous. Plain
  failures keep the existing OR fallthrough. (#220)

Changed
-------

- Geo resolution now runs against a privacy-masked view — the masked IP and an
  env with the IP-bearing headers masked — so the unmasked address never
  reaches a custom resolver or the database. Country networks are >= /24, so
  /24-masked results are identical at the default masking level. A custom
  resolver invoked through the middleware now receives the masked IP and env;
  direct ``GeoResolver.resolve`` callers are unchanged. (#206)

- Middleware pins are now recorded per *entry* rather than per class. An
  ``:outermost`` pin previously reordered every registration of that class,
  including ones registered separately with different arguments. (#219)

- ``Otto::LoggingHelpers.request_context`` masks its ``:ip`` field when the
  request never passed through ``IPPrivacyMiddleware`` (previously it fell back
  to the raw ``REMOTE_ADDR``). New ``LoggingHelpers.privacy_safe_ip`` exposes
  that behavior for callers outside Otto's stack. (#219)

- ``Otto::CaddyTLS::LocalhostGuard`` reads the new leak-free boolean
  ``env['otto.peer_loopback']`` — the loopback verdict ``IPPrivacyMiddleware``
  records on the untouched socket peer before masking — falling back to
  ``REMOTE_ADDR`` when absent. The guard still authenticates the raw peer,
  which it can no longer read directly now that IP masking runs first. (#219)

- ``RouteAuthWrapper`` multi-strategy chains now treat an anonymous success
  (a ``StrategyResult`` with no user, e.g. from ``noauth``) as a held fallback
  rather than an immediate win: the rest of the chain still runs so a later
  credentialed strategy can reject presented credentials terminally. The
  fallback wins once the chain completes without an authenticated success or
  terminal failure, preserving OR semantics for credential-less requests.
  Consequently, in ``auth=noauth,apikey`` a later authenticated success now
  wins over an earlier anonymous one. (#220)

Removed
-------

- The built-in ``KNOWN_RANGES`` IP-range guess table (and ``detect_by_range``).
  When no header, custom resolver, or database resolves a country, the result
  is now ``'**'`` (unknown) rather than a guess from a hardcoded ~14-entry
  table that mislabeled whole cloud regions. Callers that relied on the table
  (e.g. ``8.8.8.8`` -> ``US``) now get ``'**'``; configure a database or an
  edge header for real geo-location. (#206)

Fixed
-----

- IP privacy now redacts the RFC 7239 ``Forwarded`` header
  (``HTTP_FORWARDED``), which Otto reads as an authoritative client-IP source
  in count-based depth mode. Previously it was left intact while
  ``X-Forwarded-For`` and friends were masked, so downstream code could read
  the real client IP from its ``for=`` token. Only the ``for=`` value is
  replaced; ``proto=``/``host=``/``by=`` and the header structure are
  preserved. When no client IP resolves, the forwarded headers are dropped
  rather than left to leak a raw address. (#206)

- IPv4-mapped IPv6 CIDR *ranges* are now folded through ``IPAddr#native``, so
  the fold is symmetric with the client address. Previously only the client
  was folded, so a mapped range (``::ffff:10.0.0.0/104``) failed the
  address-family check and was silently skipped — a wrong verdict rather than
  an error. Affects ``Otto::Utils.ip_in_cidrs?`` / ``otto.ip_match`` and
  trusted-proxy entries, where an unmatched proxy silently withheld
  ``otto.via_trusted_proxy`` and with it ``Request#secure?`` and geo-header
  trust. **Behavior change** for anyone who configured a mapped-IPv6 range: it
  now matches the IPv4 clients it names — including ``::ffff:0:0/96``, the
  whole mapped space, which matches every IPv4 address. The prefix must cover
  the mapped marker (``/96`` or longer); ``::ffff:10.0.0.0/64`` masks the
  marker away and still matches neither form. Plain IPv4/IPv6 ranges are
  unaffected, and pre-parsed ``IPAddr`` entries are not mutated. (#218)

- ``IPPrivacyMiddleware`` reads the privacy setting per request instead of
  caching it at construction. Otto builds its middleware stack at the end of
  ``Otto.new`` while ``configure_ip_privacy`` stays legal until the first
  request, so a post-construction ``configure_ip_privacy(profile: :audit)``
  was silently ignored and the middleware kept masking. (#218)

- ``IPPrivacyMiddleware`` no longer interpolates the unmasked client IP into
  its debug log. Under ``Otto.debug``, the pre-mask resolution line
  (``:masked``, ``:anonymous``) and the private/localhost exemption line
  (``:masked``) logged the raw address — handing back through the log exactly
  what the profile withholds from env. The resolution line is gone; the
  masking path logs the masked IP, and the exemption line now records only
  that the exemption fired. ``:audit`` is unaffected. (#218)

- ``configure_ip_privacy`` is now all-or-nothing: assignments are dry-run
  against a copy and validated there before the live config is touched, so a
  rejected value (e.g. ``octet_precision: 7`` alongside a ``profile:`` preset)
  can no longer leave the preset half-applied. (#218)

- ``configure_ip_privacy`` fails loudly on falsy knobs. ``octet_precision``,
  ``hash_rotation`` and ``redis`` were truthiness-guarded, so an explicit
  ``false`` was silently dropped instead of assigned or rejected; every kwarg
  now follows the same nil guard — ``nil`` means "leave unchanged", anything
  else must take effect or raise. A non-Numeric ``hash_rotation`` raises
  ``ArgumentError`` naming the value rather than ``NoMethodError``. (#218)

- ``Otto::Privacy::Config#profile=`` raises ``ArgumentError`` for a value that
  cannot name a profile; ``config.profile = 123`` and ``config.profile = nil``
  previously raised ``NoMethodError`` on ``#to_sym``. The ``profile:`` option
  form still treats ``nil`` as "leave unchanged", but a non-nameable value now
  raises before any other option in the same call is applied. (#218)

- ``IPPrivacyMiddleware``'s idempotency guard installs a fail-closed
  ``otto.ip_match`` when ``otto.client_ip`` was set outside the middleware
  (out of contract, but previously left the advertised capability ``nil`` and
  raised ``NoMethodError`` downstream). It deliberately does not rebuild the
  check from ``otto.client_ip``, which may be masked — matching a masked
  address against a narrow CIDR yields false allows. The deny is logged.
  (#218)

- ``Otto::Request#secure?`` now honors ``env['rack.url_scheme']`` — the
  canonical Rack scheme key that ``Rack::Request#scheme``/``#ssl?`` (and
  therefore the session Secure-cookie gate, ``Rack::Protection``, and Otto's
  own CSRF middleware) read. An upstream middleware that normalizes the scheme
  the idiomatic Rack way is now visible to ``secure?`` instead of producing a
  second, divergent scheme-truth. The trusted-proxy gate on the raw
  ``X-Forwarded-Proto`` / ``X-Scheme`` headers is unchanged. (#214)

Security
--------

- Geo headers (``CF-IPCountry`` and friends, plus any configured
  ``geo_header``) are now trusted ONLY for a request that demonstrably arrived
  via a configured CIDR trusted proxy. Previously any client could pick its own
  country by sending ``CF-IPCountry``/``X-Client-Country``. An unverifiable
  origin is no longer trusted: count-based depth mode, and — a behavior change
  — deployments with **no** trusted-proxy configuration. **Migration:** to keep
  header-based geo, configure ``trusted_proxies`` (CIDR matchers) so Otto can
  verify the proxy origin. Count-based ``trusted_proxy_depth`` does NOT enable
  header trust, so depth-mode and header-only setups should set ``geo_db_path``
  for a local database instead. Otherwise resolution returns ``'**'``. (#206)

- IP masking now applies to the whole middleware stack, not just the
  application. ``IPPrivacyMiddleware`` was registered ``position: :first``,
  which is first-in-*array* and therefore **innermost**, so every other
  middleware Otto mounts — plus anything added via ``Otto#use`` — received the
  raw ``REMOTE_ADDR``, an un-anonymized User-Agent, and a nil
  ``env['otto.client_ip']``. It is now pinned outermost. (#219)

- Rate-limit logging no longer writes raw client IPs. The ``rack.attack``
  subscribers in ``Otto::Security::RateLimiting`` and ``Otto::MCP::RateLimiter``
  interpolated ``req.ip`` into a ``warn``-level line on every blocked request,
  so deployments on the default masked profile leaked public IPs to their logs.
  Both now log a masked address. (#219)

AI Assistance
-------------

- Geo-header source and local IP->country database fallback designed and
  implemented with AI assistance, including adversarial review and coverage
  for header precedence, spoofing, depth-mode trust, IPv6, custom-resolver
  sealing, boot-time validation, and the real ``maxmind-db`` reader against a
  generated fixture. (#206)

- IP precision capability, privacy profiles, middleware ordering audit, and
  terminal auth failures: design, implementation, adversarial review, and
  regression coverage developed with AI assistance. (#214, #218, #219, #220)

.. _changelog-2.6.0:

2.6.0 — 2026-07-10
==================

Added
-----

- ``Otto::Privacy::UserAgentPrivacy.anonymize(ua, max_length:)`` — public
  User-Agent anonymization, mirroring ``Otto::Privacy::IPPrivacy``. Strips
  build/version identifiers while preserving browser/OS family; idempotent.
  (delano/otto#194)

- Stable-keyed IP correlation hash: ``req.ip_correlation_hash`` /
  ``env['otto.privacy.correlation_hash']``, keyed via
  ``configure_ip_privacy(correlation_secret:)`` so the same host correlates
  across days without exposing the raw IP. (#192)

- CSP nonce policies can now be customized per-directive via
  ``enable_csp_with_nonce!(directives:)`` and ``#csp_directive_overrides=`` /
  ``#merge_csp_directives``, not just ``report-uri``/``report-to``. (#201)

Changed
-------

- ``RedactedFingerprint#anonymize_user_agent`` now delegates to
  ``UserAgentPrivacy.anonymize``; behavior is unchanged. (delano/otto#194)

- Default CSP ``worker-src`` now emits ``'self' blob:`` instead of
  ``'self' data:``. Restore the old value with
  ``directives: { worker_src: "'self' data: blob:" }``. (#201)

Fixed
-----

- ``Otto#uri`` no longer corrupts when the same handler is mounted at
  multiple paths — all routes per definition are kept, and ``uri()`` matches
  on the params given. (#190)

- ``Route#call`` no longer builds a duplicate, discarded request/response
  pair when a route handler factory is present. (#189)

- Dynamic static-file serving no longer raises ``FrozenError`` in production
  on the first request for an uncached asset. (delano/otto#185)

Security
--------

- Route loading now fails closed on malformed input: unparseable options
  warn, and malformed or mismatched-case ``auth``/``role``/``csrf`` tokens
  raise ``Otto::RouteDefinitionError`` at load instead of silently serving
  an unprotected route. (#191)

- ``klass.otto`` is no longer a shared mutable class accessor — it's now
  fiber-local, preventing concurrent requests across ``Otto`` instances from
  racing and observing the wrong security config. (#188)

- Dynamic-route and static-file dispatch now normalize request paths the
  same way literal routing does, closing a trailing-slash and
  invalid-UTF-8 divergence. (#187)

- ``csrf=exempt`` is now actually enforced at the handler layer; previously
  it was a silent no-op. **Behavior change**: ``CSRFMiddleware`` used
  standalone no longer blocks unsafe requests on its own. (#186)

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

This is the stable release of Otto v2, the culmination of 10 pre-releases
since September 2025.

Highlights
----------

- **Modular architecture**: the core ``Otto`` class is now a thin composition
  of focused modules (Router, FileSafety, Configuration, ErrorHandler,
  UriGenerator).
- **Security by default**: IP masking, user agent anonymization, CSRF
  protection, input validation, and backtrace sanitization.
- **Privacy by default**: public IP masking, country-level geo-location only
  (no external APIs), daily-rotating IP hashes for analytics.
- **Handler-level authentication**: authentication moved from middleware to
  ``RouteAuthWrapper``, so it runs after routing.
- **Configuration freezing**: configuration is frozen after the first request
  to prevent runtime security bypasses.
- **MCP support**: JSON-RPC 2.0 endpoints for CLI automation and integrations.
- **Base error classes**: ``NotFoundError``, ``BadRequestError``,
  ``ForbiddenError`` and friends, with automatic HTTP status codes.
- **Request/response helpers**: extensible ``Otto::Request`` and
  ``Otto::Response`` with application-specific helper registration.

Breaking changes
----------------

Individual breaking changes are documented in the pre-release entries below.
The migrations most applications need:

- Logic class constructor: ``initialize(session, user, params, locale)`` →
  ``initialize(context, params, locale)``
- Middleware stack: ``otto.middleware_stack <<`` → ``otto.use()``
- Request callbacks: ``Otto.on_request_complete`` → ``otto.on_request_complete``
  (instance method)

See `docs/migrating/v2.0.0.md <docs/migrating/v2.0.0.md>`__ for the full
upgrade guide.

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
