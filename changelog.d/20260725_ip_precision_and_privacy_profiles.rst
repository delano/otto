Added
-----

- Named privacy profiles: ``configure_ip_privacy(profile: :anonymous | :masked
  | :audit)`` (also accepted by ``Otto::Privacy::Config.new``). A profile is a
  validated preset over the existing knobs — ``:masked`` is the default
  posture (public IPs masked, private exempt), ``:anonymous`` masks every IP
  including private/localhost, and ``:audit`` disables IP privacy for
  private/compliance environments where granular attributability supersedes
  (retention responsibility transfers to the operator). The profile declares a
  deployment's observability posture in one reviewable word;
  ``Config#profile`` derives the label from live knob state so it can never go
  stale. Unknown names raise ``ArgumentError``.

- ``env['otto.ip_match']``: a verdict-only CIDR membership check over the
  resolved, UNMASKED client IP, installed by ``IPPrivacyMiddleware`` on every
  path that resolves an IP, under every profile. Call it with an array of
  CIDR strings (or ``IPAddr`` objects) and get ``true``/``false`` back. This
  decouples policy precision from observability posture: downstream access
  control (e.g. a per-tenant IP allowlist) can match at full /32–/128
  precision while ``otto.client_ip``, ``REMOTE_ADDR``, logs, and fingerprints
  stay masked. The unmasked address never lands in env — only the closure
  does, and a Proc serializes to nothing useful, so env dumps and loggers
  cannot leak it accidentally. Returns ``false`` when the request has no
  resolvable client IP (fail-closed for allowlist callers); invalid CIDR
  entries raise ``IPAddr::InvalidAddressError`` (configuration error).

- ``Otto::Utils.ip_in_cidrs?(ip, cidrs)``: the general-purpose CIDR-set
  matcher behind ``otto.ip_match``, sharing the trusted-proxy matcher's
  semantics — port stripping, ``IPAddr#native`` folding of IPv4-mapped IPv6,
  family-aware range skipping. Runtime ``ip`` input fails closed (nil/blank/
  malformed → ``false``); configuration ``cidrs`` entries fail fast (invalid
  → raise). Accepts pre-parsed ``IPAddr`` entries to skip re-parsing on hot
  paths.

Fixed
-----

- IPv4-mapped IPv6 CIDR *ranges* are now folded through ``IPAddr#native``, so
  the fold is symmetric with the client address. Previously only the client
  was folded, so a mapped range (``::ffff:10.0.0.0/104``) failed the
  address-family check and was silently skipped — a wrong verdict rather than
  an error. Affects both ``Otto::Utils.ip_in_cidrs?`` / ``otto.ip_match`` and
  trusted-proxy entries, where an unmatched proxy silently withheld
  ``otto.via_trusted_proxy`` and with it ``Request#secure?`` and geo-header
  trust. Behavior change for anyone who configured a mapped-IPv6 range: it
  now matches the IPv4 clients it names — including ``::ffff:0:0/96``, which
  is the whole mapped space and so matches every IPv4 address. Deprecated
  IPv4-compatible notation (``::a.b.c.d``) folds on the same terms. The
  prefix must cover the mapped marker (``/96`` or longer); a shorter one
  such as ``::ffff:10.0.0.0/64`` masks the marker away and still matches
  neither form. Plain IPv4 and IPv6 ranges are unaffected, and pre-parsed
  ``IPAddr`` entries are not mutated (frozen ones included).

- ``IPPrivacyMiddleware`` reads the privacy setting per request instead of
  caching it at construction. Otto builds its middleware stack at the end of
  ``Otto.new`` while ``configure_ip_privacy`` stays legal until the first
  request, so a post-construction ``configure_ip_privacy(profile: :audit)``
  was silently ignored and the middleware kept masking.

- ``IPPrivacyMiddleware`` no longer interpolates the resolved, unmasked client
  IP into its debug log. Both masking paths logged the raw address when
  ``Otto.debug`` was on — the pre-mask resolution line under ``:masked`` and
  ``:anonymous``, and the private/localhost exemption line under ``:masked`` —
  handing back through the log exactly what the profile withholds from env, and
  to a destination that typically travels further than the process. The masked
  value is still logged after masking. ``:audit`` is unaffected: it keeps the
  raw IP in env by design and takes a path that never logged it.

- ``Otto::Privacy::Config.profile_presets`` raises ``ArgumentError`` for a
  profile that is not a Symbol or String. ``profile: 123`` or an explicit
  ``profile: nil`` previously raised ``NoMethodError`` on ``#to_sym``,
  inconsistent with the rest of the class's input validation.

- ``IPPrivacyMiddleware``'s idempotency guard installs a fail-closed
  ``otto.ip_match`` when ``otto.client_ip`` was set outside the middleware
  (out of contract, but previously left the advertised capability ``nil`` and
  raised ``NoMethodError`` downstream). It deliberately does not rebuild the
  check from ``otto.client_ip``, which may be masked — matching a masked
  address against a narrow CIDR yields false allows. The deny is logged.
