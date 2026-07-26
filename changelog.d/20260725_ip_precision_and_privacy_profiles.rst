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
