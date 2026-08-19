Added
-----

- Request-scoped CSP directive extras (#243): an opt-in channel for widening
  directives with values only known at request time. The app opts in at boot
  with ``security_config.enable_csp_request_extras!`` (default OFF — the env
  key is a write surface any middleware in the Rack stack can reach, so the
  channel does not exist until boot code says so). With the channel enabled,
  a handler writes a hash of directive name => additional source tokens to
  ``env['otto.csp.extra_directives']`` before the response is finalized, and
  every emission surface (``Otto::Response#apply_csp`` via its wired request,
  the ``EmitMiddleware`` backstop, and ``Writer.apply(..., env:)``) folds the
  sanitized survivors ADDITIVELY into the policy at build time. The
  motivating case is multi-tenant installs that must admit the resolved
  tenant's SSO IdP origin into ``form-action`` — per-request data no
  boot-time ``csp_directive_overrides`` can express. New public API:
  ``Otto::Security::Config#enable_csp_request_extras!`` /
  ``#csp_request_extras_enabled?``,
  ``Otto::Security::CSP::RequestExtras.from_env`` (returns nil when the key
  is absent, malformed, or nothing survived sanitization — never an empty
  hash), ``Policy.append_extra_sources`` (pure: returns
  ``[merged, applied, dropped]``, no logging), an ``extra_directives:``
  keyword plus an optional applied/dropped outcome block on
  ``Config#generate_nonce_csp`` / ``Policy.nonce_policy``, an ``env:``
  keyword on ``Writer.apply``, an ``extra_directives`` reader on
  ``Writer::Result`` (only the extras that ACTUALLY landed in the policy),
  and ``Otto::EnvKeys::CSP::EXTRA_DIRECTIVES``. Extras live in the env only —
  nothing is memoized on the deep-frozen production config, so concurrent
  requests cannot bleed into each other.

Security
--------

- The extras channel is additive-only and validated defensively (#243):
  tokens must be http(s) origins (``scheme://host[:port]``, normalized, no
  paths/userinfo/query, no keywords or scheme sources, no wildcards, no
  ``;``/CR/LF, no ``%`` in the host, explicit ports limited to 1..65535, a
  single trailing host dot stripped and any further trailing dot rejected),
  the ``script-src`` family and ``default-src`` are refused wholesale
  (defence-in-depth — appends would keep the nonce regardless), and a
  directive absent from the built policy is never created (that would
  TIGHTEN the policy, since e.g. ``form-action`` does not fall back to
  ``default-src``) nor a boot-removed one resurrected. Every rejected
  key/token is dropped and logged at ``:warn`` with a distinct reason and
  request context — request-time input never raises (a config with the
  pre-#243 ``generate_nonce_csp`` signature falls back to the legacy call
  shape, dropping the extras with a single warn), and the response ships
  with the rest of the policy byte-identical to the no-extras build.
