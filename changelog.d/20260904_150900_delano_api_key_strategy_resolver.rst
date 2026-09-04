Added
-----

- ``Otto::Security::Authentication::Strategies::APIKeyStrategy`` accepts a
  resolver as an alternative to a static key list, so an application can look
  a presented key up in a database, repository, or cache and return the
  account behind it. Pass a block, ``APIKeyStrategy.new { |key| ... }``, or
  any object that responds to ``#call`` as ``resolver:``, e.g.
  ``APIKeyStrategy.new(resolver: repo.method(:find_by_key))``. Exactly one of
  ``api_keys:``, ``resolver:``, or a block must be given; passing none or more
  than one raises ``ArgumentError``. The resolver receives only the presented
  key as a non-empty ``String``; a ``nil`` or ``false`` return is the same
  terminal ``Invalid API key`` failure as a static mismatch, exceptions from
  the resolver propagate rather than becoming a 401 or a success, and the
  result still carries ``api_key_fingerprint`` in its metadata while the raw
  key never reaches the result, environment, session, or logs.

- ``APIKeyStrategy.digest(key)`` returns the full SHA-256 hex digest of a key.
  The documented resolver pattern stores digests instead of raw keys and looks
  up by ``APIKeyStrategy.digest(presented_key)``, which is constant-time by
  construction and keeps raw credentials out of the database.
