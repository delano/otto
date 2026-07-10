Added
-----

- CSP nonce policies can now be customized per-directive (#201).
  ``Otto::Security::Config#enable_csp_with_nonce!`` accepts a ``directives:``
  hash, and the new ``#csp_directive_overrides=`` / ``#merge_csp_directives``
  setters let a consuming app override, add, or remove ANY directive rather
  than only ``report-uri``/``report-to``. Overrides merge into Otto's base
  directive sets (``Otto::Security::CSP::Policy.merge_directives``): a String
  or Array value replaces a directive's source list, and a ``nil``/``false``
  value removes the directive. This gives apps a supported escape hatch — for
  example ``enable_csp_with_nonce!(directives: { 'worker-src' => "'self' blob:" })``
  to permit ``blob:`` workers (Sentry Replay, VueUse ``useWebWorkerFn``,
  bundler-emitted workers, WASM loaders) — without vendoring the gem. Output
  is byte-identical to Otto's historical policy when no overrides are set; the
  default ``worker-src 'self' data:`` is unchanged so the production policy is
  not relaxed for every consumer. Directive names and source tokens are
  validated — a value containing ``;``, a newline, or a carriage return raises
  ``ArgumentError`` rather than injecting extra directives (a footgun when
  overrides come from env/config files) — and override keys are normalized on
  store so mixed key styles never accumulate duplicate entries.
