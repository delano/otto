Added
-----

- ``APIKeyStrategy`` now accepts a block or ``resolver:`` callable instead of a
  static ``api_keys:`` list, enabling database-, repository-, or cache-backed
  key lookup. The resolved account becomes the authenticated user.

- ``APIKeyStrategy.digest(key)`` returns a full SHA-256 hex digest for stores
  that look up generated API keys by digest. See
  ``docs/guides/authentication.md`` for the resolver contract and credential
  storage guidance.

Fixed
-----

- ``StrategyResult#has_role?`` and ``#has_permission?`` now derive their answer
  from ``#roles`` and ``#permissions``, so the predicates agree with the
  accessors for object-backed users exposing ``#roles`` and for ``Set`` or
  other non-Array collections. A user model defining its own ``#has_role?`` or
  ``#has_permission?`` is still consulted first.
