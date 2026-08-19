Security
--------

- Refuse request-scoped CSP extras targeting valueless directives
  (``upgrade-insecure-requests`` and ``block-all-mixed-content``) during
  sanitization (#243). The policy assembler retains its independent guard for
  direct ``Policy.nonce_policy(extra_directives:)`` callers that bypass the
  request sanitizer.
