Changed
-------

- The nonce CSP's default ``worker-src`` directive now emits ``'self' blob:``
  instead of ``'self' data:`` in both the production and development directive
  sets (#201). Browsers instantiate Web Workers from ``blob:`` URLs
  (``new Worker(URL.createObjectURL(...))``) — the mechanism used by Sentry
  Replay, VueUse ``useWebWorkerFn``, bundler-emitted workers, and WASM
  loaders — so the previous default blocked mainstream worker libraries while
  granting ``data:``, a token real libraries don't use and one that is riskier
  under content injection (an attacker fully controls a ``data:`` URL's
  content, whereas a ``blob:`` URL must be minted by same-origin script
  already gated by the ``script-src`` nonce). Apps that genuinely rely on
  ``data:`` workers can restore the old behavior in one line:
  ``enable_csp_with_nonce!(directives: { worker_src: "'self' data: blob:" })``.

Added
-----

- CSP nonce policies can now be customized per-directive (#201).
  ``Otto::Security::Config#enable_csp_with_nonce!`` accepts a ``directives:``
  hash, and the new ``#csp_directive_overrides=`` / ``#merge_csp_directives``
  setters let a consuming app override, add, or remove ANY directive rather
  than only ``report-uri``/``report-to``. Overrides merge into Otto's base
  directive sets (``Otto::Security::CSP::Policy.merge_directives``): a String
  or Array value replaces a directive's source list, and a ``nil``/``false``
  value removes the directive. Output is byte-identical to the (updated)
  default policy when no overrides are set. Directive names and source tokens
  are validated — a value containing ``;``, a newline, or a carriage return
  raises ``ArgumentError`` rather than injecting extra directives (a footgun
  when overrides come from env/config files) — and override keys are
  normalized on store so mixed key styles never accumulate duplicate entries.
  Overriding ``script-src`` while nonce mode is enabled logs a warning: the
  per-request nonce cannot be reproduced in a static override, so such an
  override disables nonce-based script protection for that policy.
