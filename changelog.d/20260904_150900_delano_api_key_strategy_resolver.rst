Added
-----

- ``APIKeyStrategy`` now accepts a block or ``resolver:`` callable instead of a
  static ``api_keys:`` list, enabling database-, repository-, or cache-backed
  key lookup. The resolved account becomes the authenticated user.

- ``APIKeyStrategy.digest(key)`` returns a full SHA-256 hex digest for stores
  that look up generated API keys by digest. See
  ``docs/guides/authentication.md`` for the resolver contract and credential
  storage guidance.
