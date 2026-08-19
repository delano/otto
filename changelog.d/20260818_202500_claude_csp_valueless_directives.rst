Fixed
-----

- CSP request extras keyed to a directive that takes no value no longer
  corrupt it (#243). ``upgrade-insecure-requests`` and
  ``block-all-mixed-content`` carry no source list, so appending an extra
  origin emitted ``upgrade-insecure-requests https://idp.example.com;`` —
  syntactically malformed, which browsers discard wholesale, silently turning
  the directive OFF instead of widening it. ``Policy.append_extra_sources``
  now leaves such a directive BYTE-IDENTICAL and reports the entry through the
  same ``dropped`` channel as an absent directive (never applied, never
  silently discarded); the new ``Policy::VALUELESS_DIRECTIVES`` constant and
  ``Policy.valueless_directive?`` predicate name the set, matched through the
  shared ``Policy.normalize_directive_name`` so ``:upgrade_insecure_requests``
  and ``'Upgrade-Insecure-Requests'`` are caught too. ``Writer`` logs these
  drops with ``reason: :valueless_directive`` (distinct from
  ``:absent_directive`` — the entry is an app bug, not a policy gap). Other
  entries in the same request are unaffected: one bad key does not poison the
  batch. Scope is limited to the two valueless directives; ``sandbox``,
  ``trusted-types``, and ``require-trusted-types-for`` still accept appends
  since they produce valid syntax.
